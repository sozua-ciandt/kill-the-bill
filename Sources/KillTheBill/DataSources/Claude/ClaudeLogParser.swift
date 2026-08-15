import Foundation

// MARK: - Native transcript shapes

private struct TranscriptEntry: Decodable {
    let type: String?
    let message: MessageBlock?
    let timestamp: String?
}

private struct MessageBlock: Decodable {
    let id: String?
    let role: String?
    let model: String?
    let usage: UsageBlock?
}

private struct UsageBlock: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
}

// MARK: - Parser

enum ClaudeLogParser {

    static func parseTranscripts(dirs: [URL], files: [URL], pricing: ModelPricing) -> DailyUsage {
        parseTranscripts(dirs: dirs, files: files, pricing: pricing, dateFilter: nil)
    }

    static func parseTranscripts(
        dirs: [URL],
        files: [URL],
        pricing: ModelPricing,
        dateFilter: DateComponents?
    ) -> DailyUsage {
        var accumulator = UsageAccumulator()
        let decoder = JSONDecoder()
        let calendar = Calendar.current

        for file in files {
            let parentDir = projectDirName(for: file, in: dirs)
            let projectName = LogScanner.projectName(from: parentDir)

            var seenUsage: Set<String> = []
            var hasUsageInPeriod = false

            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(TranscriptEntry.self, from: lineData),
                      entry.type == "assistant",
                      let msg = entry.message,
                      let usage = msg.usage else { continue }

                // Filter by timestamp when a date is specified; fall through if no timestamp.
                if let filter = dateFilter, let ts = entry.timestamp {
                    guard let date = ParserHelpers.parseISO8601(ts),
                          ParserHelpers.matchesFilter(date, filter: filter, calendar: calendar)
                    else { continue }
                }

                let input = usage.input_tokens ?? 0
                let output = usage.output_tokens ?? 0
                let cacheW = usage.cache_creation_input_tokens ?? 0
                let cacheR = usage.cache_read_input_tokens ?? 0

                // Prefer message.id (stable API identifier); fall back to token fingerprint.
                let dedupKey = msg.id ?? "\(input):\(output):\(cacheW):\(cacheR)"
                guard seenUsage.insert(dedupKey).inserted else { continue }

                let rawModel = msg.model ?? "unknown"
                let modelKey = ModelPricing.normalizeModel(rawModel)
                let cost = pricing.cost(model: rawModel, input: input, output: output,
                                        cacheWrite: cacheW, cacheRead: cacheR)

                accumulator.addTurn(
                    workspaceID: projectName,
                    displayName: projectName,
                    modelID: modelKey,
                    input: input,
                    output: output,
                    cacheWrite: cacheW,
                    cacheRead: cacheR,
                    costUSD: cost
                )
                hasUsageInPeriod = true
            }

            if hasUsageInPeriod {
                accumulator.registerSession(
                    file,
                    logicalSessionID: logicalSessionID(for: file),
                    workspaceID: projectName,
                    displayName: projectName
                )
            }
        }

        return accumulator.dailyUsage()
    }

    static func countMonthlyTurns(files: [URL]) -> Int {
        countMonthlyTurns(files: files, monthFilter: nil)
    }

    static func countMonthlyTurns(files: [URL], monthFilter: DateComponents?) -> Int {
        let decoder = JSONDecoder()
        let calendar = Calendar.current
        var total = 0

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            var seen: Set<String> = []
            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(TranscriptEntry.self, from: lineData),
                      entry.type == "assistant",
                      let usage = entry.message?.usage else { continue }

                if let filter = monthFilter, let ts = entry.timestamp {
                    guard let date = ParserHelpers.parseISO8601(ts),
                          ParserHelpers.matchesFilter(date, filter: filter, calendar: calendar)
                    else { continue }
                }

                let msgID = entry.message?.id
                let key = msgID ?? "\(usage.input_tokens ?? 0):\(usage.output_tokens ?? 0):\(usage.cache_creation_input_tokens ?? 0):\(usage.cache_read_input_tokens ?? 0)"
                if seen.insert(key).inserted { total += 1 }
            }
        }

        return total
    }

    // MARK: - Helpers

    /// Claude stores child-agent transcripts under
    /// `<project>/<root-session-id>/subagents/agent-*.jsonl`. They contribute
    /// usage to the root conversation but are not independent sessions.
    private static func logicalSessionID(for file: URL) -> String {
        let standardized = file.standardizedFileURL
        let components = standardized.pathComponents
        guard components.lastIndex(of: "subagents") != nil else {
            return standardized.resolvingSymlinksInPath().path
        }

        let subagentsDirectory = standardized.deletingLastPathComponent()
        guard subagentsDirectory.lastPathComponent == "subagents" else {
            return standardized.resolvingSymlinksInPath().path
        }

        let sessionDirectory = subagentsDirectory.deletingLastPathComponent()
        let rootSessionID = sessionDirectory.lastPathComponent
        guard !rootSessionID.isEmpty else {
            return standardized.resolvingSymlinksInPath().path
        }

        return sessionDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(rootSessionID)
            .appendingPathExtension("jsonl")
            .resolvingSymlinksInPath()
            .path
    }

    /// Resolve the top-level project directory name for a file that may be nested
    /// arbitrarily deep (e.g. inside a `subagents/` subfolder).
    private static func projectDirName(for file: URL, in dirs: [URL]) -> String {
        let filePath = file.standardizedFileURL.path
        for dir in dirs {
            let dirPath = dir.standardizedFileURL.path
            if filePath.hasPrefix(dirPath + "/") {
                return dir.lastPathComponent
            }
        }
        return file.deletingLastPathComponent().lastPathComponent
    }

}

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
        let calendar = Calendar.current

        for file in files {
            let parentDir = projectDirName(for: file, in: dirs)
            let projectName = LogScanner.projectName(from: parentDir)

            var seenUsage: Set<String> = []
            var hasUsageInPeriod = false

            SessionJSONLineReader.forEachObject(at: file) { entry in
                guard (entry["type"] as? String) == "assistant",
                      let msg = entry["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { return }

                // Filter by timestamp when a date is specified; fall through if no timestamp.
                if let filter = dateFilter, let ts = entry["timestamp"] as? String {
                    guard let date = ParserHelpers.parseISO8601(ts),
                          ParserHelpers.matchesFilter(date, filter: filter, calendar: calendar)
                    else { return }
                }

                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheW = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cacheR = usage["cache_read_input_tokens"] as? Int ?? 0

                // Prefer message.id (stable API identifier); fall back to token fingerprint.
                let dedupKey = (msg["id"] as? String) ?? "\(input):\(output):\(cacheW):\(cacheR)"
                guard seenUsage.insert(dedupKey).inserted else { return }

                let rawModel = (msg["model"] as? String) ?? "unknown"
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

    static func parseTranscriptsOverview(
        dirs: [URL],
        files: [URL],
        pricing: ModelPricing,
        todayFilter: DateComponents,
        monthFilter: DateComponents
    ) -> (today: DailyUsage, month: DailyUsage) {
        var todayAccumulator = UsageAccumulator()
        var monthAccumulator = UsageAccumulator()
        let calendar = Calendar.current

        for file in files {
            let parentDir = projectDirName(for: file, in: dirs)
            let projectName = LogScanner.projectName(from: parentDir)

            var seenUsageMonth: Set<String> = []
            var seenUsageToday: Set<String> = []
            var hasMonthUsage = false
            var hasTodayUsage = false

            SessionJSONLineReader.forEachObject(at: file) { entry in
                guard (entry["type"] as? String) == "assistant",
                      let msg = entry["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { return }

                let entryDate: Date?
                if let ts = entry["timestamp"] as? String {
                    entryDate = ParserHelpers.parseISO8601(ts)
                } else {
                    entryDate = nil
                }

                let matchesMonth: Bool
                if let entryDate {
                    matchesMonth = ParserHelpers.matchesFilter(entryDate, filter: monthFilter, calendar: calendar)
                } else {
                    matchesMonth = true
                }

                guard matchesMonth else { return }

                let matchesToday: Bool
                if let entryDate {
                    matchesToday = ParserHelpers.matchesFilter(entryDate, filter: todayFilter, calendar: calendar)
                } else {
                    matchesToday = false
                }

                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheW = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cacheR = usage["cache_read_input_tokens"] as? Int ?? 0

                let dedupKey = (msg["id"] as? String) ?? "\(input):\(output):\(cacheW):\(cacheR)"

                let rawModel = (msg["model"] as? String) ?? "unknown"
                let modelKey = ModelPricing.normalizeModel(rawModel)
                let cost = pricing.cost(model: rawModel, input: input, output: output,
                                        cacheWrite: cacheW, cacheRead: cacheR)

                if seenUsageMonth.insert(dedupKey).inserted {
                    monthAccumulator.addTurn(
                        workspaceID: projectName,
                        displayName: projectName,
                        modelID: modelKey,
                        input: input,
                        output: output,
                        cacheWrite: cacheW,
                        cacheRead: cacheR,
                        costUSD: cost
                    )
                    hasMonthUsage = true
                }

                if matchesToday, seenUsageToday.insert(dedupKey).inserted {
                    todayAccumulator.addTurn(
                        workspaceID: projectName,
                        displayName: projectName,
                        modelID: modelKey,
                        input: input,
                        output: output,
                        cacheWrite: cacheW,
                        cacheRead: cacheR,
                        costUSD: cost
                    )
                    hasTodayUsage = true
                }
            }

            let logicalID = logicalSessionID(for: file)
            if hasMonthUsage {
                monthAccumulator.registerSession(
                    file,
                    logicalSessionID: logicalID,
                    workspaceID: projectName,
                    displayName: projectName
                )
            }
            if hasTodayUsage {
                todayAccumulator.registerSession(
                    file,
                    logicalSessionID: logicalID,
                    workspaceID: projectName,
                    displayName: projectName
                )
            }
        }

        return (todayAccumulator.dailyUsage(), monthAccumulator.dailyUsage())
    }

    static func countMonthlyTurns(files: [URL]) -> Int {
        countMonthlyTurns(files: files, monthFilter: nil)
    }

    static func countMonthlyTurns(files: [URL], monthFilter: DateComponents?) -> Int {
        let calendar = Calendar.current
        var total = 0

        for file in files {
            var seen: Set<String> = []
            SessionJSONLineReader.forEachObject(at: file) { entry in
                guard (entry["type"] as? String) == "assistant",
                      let msg = entry["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { return }

                if let filter = monthFilter, let ts = entry["timestamp"] as? String {
                    guard let date = ParserHelpers.parseISO8601(ts),
                          ParserHelpers.matchesFilter(date, filter: filter, calendar: calendar)
                    else { return }
                }

                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheW = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cacheR = usage["cache_read_input_tokens"] as? Int ?? 0

                let dedupKey = (msg["id"] as? String) ?? "\(input):\(output):\(cacheW):\(cacheR)"
                if seen.insert(dedupKey).inserted { total += 1 }
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

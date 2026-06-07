import Foundation

// MARK: - Native transcript shapes

private struct TranscriptEntry: Decodable {
    let type: String?
    let message: MessageBlock?
    let timestamp: String?
}

private struct MessageBlock: Decodable {
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
        var accumulator = UsageAccumulator()

        let decoder = JSONDecoder()

        for file in files {
            let parentDir = file.deletingLastPathComponent().lastPathComponent
            let projectName = LogScanner.projectName(from: parentDir)
            accumulator.registerSession(file, workspaceID: projectName, displayName: projectName)

            var seenUsage: Set<String> = []

            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(TranscriptEntry.self, from: lineData),
                      entry.type == "assistant",
                      let msg = entry.message,
                      let usage = msg.usage else { continue }

                let input = usage.input_tokens ?? 0
                let output = usage.output_tokens ?? 0
                let cacheW = usage.cache_creation_input_tokens ?? 0
                let cacheR = usage.cache_read_input_tokens ?? 0

                let dedupKey = "\(input):\(output):\(cacheW):\(cacheR)"
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
            }
        }

        return accumulator.dailyUsage()
    }

    /// Fast turn-only count for monthly files — skips cost/token aggregation.
    static func countMonthlyTurns(files: [URL]) -> Int {
        let decoder = JSONDecoder()
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

                let key = "\(usage.input_tokens ?? 0):\(usage.output_tokens ?? 0):\(usage.cache_creation_input_tokens ?? 0):\(usage.cache_read_input_tokens ?? 0)"
                if seen.insert(key).inserted { total += 1 }
            }
        }

        return total
    }
}

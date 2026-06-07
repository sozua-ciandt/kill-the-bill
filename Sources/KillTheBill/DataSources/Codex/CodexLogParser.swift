import Foundation

private struct CodexEntry: Decodable {
    let type: String?
    let payload: CodexPayload?
}

private struct CodexPayload: Decodable {
    let type: String?
    let cwd: String?
    let model: String?
    let info: CodexTokenInfo?
}

private struct CodexTokenInfo: Decodable {
    let last_token_usage: CodexTokenUsage?
}

private struct CodexTokenUsage: Decodable {
    let input_tokens: Int?
    let cached_input_tokens: Int?
    let output_tokens: Int?
    let total_tokens: Int?
}

enum CodexLogParser {
    static func parseSessions(files: [URL], pricing: ModelPricing) -> DailyUsage {
        var accumulator = UsageAccumulator()
        let decoder = JSONDecoder()

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            var currentWorkspace = workspaceName(from: nil)
            var currentModel = "unknown"

            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(CodexEntry.self, from: lineData) else {
                    continue
                }

                if entry.type == "session_meta", let cwd = entry.payload?.cwd {
                    currentWorkspace = workspaceName(from: cwd)
                    accumulator.registerSession(file, workspaceID: currentWorkspace, displayName: currentWorkspace)
                    continue
                }

                if entry.type == "turn_context" {
                    if let cwd = entry.payload?.cwd {
                        currentWorkspace = workspaceName(from: cwd)
                    }
                    if let model = entry.payload?.model {
                        currentModel = model
                    }
                    continue
                }

                guard entry.type == "event_msg",
                      entry.payload?.type == "token_count",
                      let usage = entry.payload?.info?.last_token_usage else {
                    continue
                }

                let rawInput = usage.input_tokens ?? 0
                let cacheRead = min(rawInput, usage.cached_input_tokens ?? 0)
                let input = max(rawInput - cacheRead, 0)
                let output = usage.output_tokens ?? 0
                let detailedTokens = rawInput + output
                let totalTokens = usage.total_tokens ?? detailedTokens

                guard detailedTokens > 0 || totalTokens > 0 else { continue }

                let modelID = ModelPricing.normalizeProviderModel(currentModel)
                let cost = detailedTokens > 0
                    ? pricing.cost(
                        model: currentModel,
                        rawInput: rawInput,
                        output: output,
                        cachedInput: cacheRead
                    )
                    : nil

                accumulator.addTurn(
                    workspaceID: currentWorkspace,
                    displayName: currentWorkspace,
                    modelID: modelID,
                    input: input,
                    output: output,
                    cacheWrite: 0,
                    cacheRead: cacheRead,
                    costUSD: cost
                )
            }
        }

        return accumulator.dailyUsage()
    }

    static func countMonthlyTurns(files: [URL]) -> Int {
        let decoder = JSONDecoder()
        var total = 0

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(CodexEntry.self, from: lineData),
                      entry.type == "event_msg",
                      entry.payload?.type == "token_count",
                      let usage = entry.payload?.info?.last_token_usage else {
                    continue
                }

                let input = usage.input_tokens ?? 0
                let cacheRead = usage.cached_input_tokens ?? 0
                let output = usage.output_tokens ?? 0
                let tokenTotal = usage.total_tokens ?? (input + output)
                if input > 0 || cacheRead > 0 || output > 0 || tokenTotal > 0 {
                    total += 1
                }
            }
        }

        return total
    }

    private static func workspaceName(from cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Codex" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

import Foundation

// MARK: - Data models

struct WorkspaceUsage: Identifiable, Sendable {
    let id: String
    var displayName: String
    var costUSD: Double
    var inputTokens: Int
    var outputTokens: Int
    var cacheWriteTokens: Int
    var cacheReadTokens: Int
    var sessionCount: Int
    var turnCount: Int
}

struct ModelUsage: Identifiable, Sendable {
    let id: String      // normalized model name
    var costUSD: Double
    var turnCount: Int
}

struct DailyUsage: Sendable {
    var totalCostUSD: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheReadTokens: Int = 0
    var sessionCount: Int = 0
    var turnCount: Int = 0
    var monthlyTurnCount: Int = 0
    var lastUpdated: Date = .distantPast
    var perWorkspace: [WorkspaceUsage] = []
    var perModel: [ModelUsage] = []

    var totalTokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }
}

// MARK: - Pricing table (USD per million tokens)

private let pricing: [String: (input: Double, output: Double, cacheWrite: Double, cacheRead: Double)] = [
    "claude-opus-4-8":   (15,    75,   18.75,  1.50),
    "claude-opus-4-6":   (15,    75,   18.75,  1.50),
    "claude-sonnet-4-6": ( 3,    15,    3.75,  0.30),
    "claude-sonnet-4-5": ( 3,    15,    3.75,  0.30),
    "claude-haiku-4-5":  ( 0.80,  4,    1.00,  0.08),
]

private func normalizeModel(_ raw: String) -> String {
    raw.replacingOccurrences(of: "anthropic.", with: "")
       .replacing(#/-\d{8}$/#, with: "")
}

private func computeCost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
    let key = normalizeModel(model)
    guard let p = pricing[key] else { return 0 }
    let M = 1_000_000.0
    return (Double(input) / M * p.input)
         + (Double(output) / M * p.output)
         + (Double(cacheWrite) / M * p.cacheWrite)
         + (Double(cacheRead) / M * p.cacheRead)
}

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

enum LogParser {

    static func parseTranscripts(dirs: [URL], files: [URL]) -> DailyUsage {
        var workspaces: [String: WorkspaceUsage] = [:]
        var models: [String: ModelUsage] = [:]
        var lastDate: Date = .distantPast
        var sessionFiles: Set<String> = []

        let decoder = JSONDecoder()

        for file in files {
            let parentDir = file.deletingLastPathComponent().lastPathComponent
            let projectName = LogScanner.projectName(from: parentDir)
            sessionFiles.insert(file.path)

            var seenUsage: Set<String> = []

            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            if let modDate = try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate, modDate > lastDate {
                lastDate = modDate
            }

            if workspaces[projectName] == nil {
                workspaces[projectName] = WorkspaceUsage(
                    id: projectName, displayName: projectName,
                    costUSD: 0, inputTokens: 0, outputTokens: 0,
                    cacheWriteTokens: 0, cacheReadTokens: 0,
                    sessionCount: 0, turnCount: 0
                )
            }
            workspaces[projectName]?.sessionCount += 1

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
                let modelKey = normalizeModel(rawModel)
                let cost = computeCost(model: rawModel, input: input, output: output,
                                       cacheWrite: cacheW, cacheRead: cacheR)

                workspaces[projectName]?.inputTokens += input
                workspaces[projectName]?.outputTokens += output
                workspaces[projectName]?.cacheWriteTokens += cacheW
                workspaces[projectName]?.cacheReadTokens += cacheR
                workspaces[projectName]?.costUSD += cost
                workspaces[projectName]?.turnCount += 1

                if models[modelKey] == nil {
                    models[modelKey] = ModelUsage(id: modelKey, costUSD: 0, turnCount: 0)
                }
                models[modelKey]?.costUSD += cost
                models[modelKey]?.turnCount += 1
            }
        }

        let allWs = workspaces.values.sorted { $0.costUSD > $1.costUSD }
        let allModels = models.values.sorted { $0.costUSD > $1.costUSD }

        return DailyUsage(
            totalCostUSD: allWs.reduce(0) { $0 + $1.costUSD },
            inputTokens: allWs.reduce(0) { $0 + $1.inputTokens },
            outputTokens: allWs.reduce(0) { $0 + $1.outputTokens },
            cacheWriteTokens: allWs.reduce(0) { $0 + $1.cacheWriteTokens },
            cacheReadTokens: allWs.reduce(0) { $0 + $1.cacheReadTokens },
            sessionCount: sessionFiles.count,
            turnCount: allWs.reduce(0) { $0 + $1.turnCount },
            lastUpdated: lastDate == .distantPast ? Date() : lastDate,
            perWorkspace: allWs,
            perModel: allModels
        )
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

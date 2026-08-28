import Foundation

struct BaseSessionEventInvocation: Sendable {
    let rawModel: String
    let normalizedModel: String
    let tokens: SessionTokenUsage
    let date: Date?
}

struct BaseSessionEventHumanTurn: Sendable {
    let id: String?
    let date: Date?
}

struct BaseSessionEventToolCall: Sendable {
    let id: String
    let name: String
    let mcpServer: String?
    let mcpTool: String?
    let date: Date?
}

struct BaseSessionEventToolResult: Sendable {
    let callID: String
    let payloadEstimate: SessionResultTokenEstimate
    let isError: Bool
    let date: Date?
}

struct BaseSessionEventAgentSummary: Sendable {
    let agentID: String
    let name: String?
    let kind: String?
    let status: String?
    let date: Date?
    let rawModel: String
    let normalizedModel: String
    let tokens: SessionTokenUsage
    let invocationCount: Int
    let toolCallCount: Int
    let totalTokens: Int
}

struct BaseSessionEventSliceActivity: Sendable {
    let date: Date?
}

struct BaseSessionFragment: Sendable {
    let harness: SessionHarness
    var id: String
    var parentID: String?
    var isSubagent: Bool
    var name: String?
    var kind: String?
    var status: String?
    var title: String?
    var preview: String?
    var repositoryPath: String?
    var repositoryFallbackName: String
    var gitBranch: String?
    var startedAt: Date?
    var lastActivityAt: Date?
    var spawnedAgentIDs: Set<String> = []

    var invocations: [BaseSessionEventInvocation] = []
    var humanTurns: [BaseSessionEventHumanTurn] = []
    var toolCalls: [BaseSessionEventToolCall] = []
    var toolResults: [BaseSessionEventToolResult] = []
    var agentSummaries: [BaseSessionEventAgentSummary] = []
    var sliceActivities: [BaseSessionEventSliceActivity] = []

    mutating func observeLifetimeDate(_ date: Date?) {
        guard let date else { return }
        if startedAt == nil || date < startedAt! { startedAt = date }
        if lastActivityAt == nil || date > lastActivityAt! { lastActivityAt = date }
    }

    func slice(pricing: ModelPricing, interval: DateInterval?) -> ParsedSessionFragment {
        var fragment = ParsedSessionFragment(
            harness: harness,
            id: id,
            parentID: parentID,
            isSubagent: isSubagent,
            name: name,
            kind: kind,
            status: status,
            title: title,
            preview: preview,
            repositoryPath: repositoryPath,
            repositoryFallbackName: repositoryFallbackName,
            gitBranch: gitBranch,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            spawnedAgentIDs: spawnedAgentIDs
        )

        for inv in invocations {
            let hasDetailedUsage = inv.tokens.knownTotalTokens > 0
            let cost = hasDetailedUsage
                ? pricing.cost(
                    model: inv.rawModel,
                    input: inv.tokens.inputTokens,
                    output: inv.tokens.outputTokens,
                    cacheWrite: inv.tokens.cacheWriteTokens,
                    cacheRead: inv.tokens.cacheReadTokens
                )
                : nil
            fragment.addInvocation(
                model: inv.normalizedModel,
                tokens: inv.tokens,
                costUSD: cost,
                at: inv.date,
                interval: interval
            )
        }

        for turn in humanTurns {
            fragment.addHumanTurn(id: turn.id, at: turn.date, interval: interval)
        }

        for call in toolCalls {
            fragment.addToolCall(
                id: call.id,
                name: call.name,
                mcpServer: call.mcpServer,
                mcpTool: call.mcpTool,
                at: call.date,
                interval: interval
            )
        }

        for res in toolResults {
            guard sessionIncludes(res.date, in: interval), var call = fragment.toolCalls[res.callID] else { continue }
            call.isError = call.isError || res.isError
            if call.resultTokens == nil {
                call.resultTokens = res.payloadEstimate
            }
            fragment.toolCalls[res.callID] = call
        }

        for summary in agentSummaries {
            guard sessionIncludes(summary.date, in: interval) else { continue }
            let cost = pricing.cost(
                model: summary.rawModel,
                input: summary.tokens.inputTokens,
                output: summary.tokens.outputTokens,
                cacheWrite: summary.tokens.cacheWriteTokens,
                cacheRead: summary.tokens.cacheReadTokens
            )
            var usage = SessionUsage(
                tokens: summary.tokens,
                pricedCostUSD: cost ?? 0,
                modelInvocationCount: summary.invocationCount,
                unpricedModelInvocationCount: cost == nil ? summary.invocationCount : 0
            )
            if summary.tokens.reportedTotalTokens == 0 && summary.totalTokens > 0 {
                usage.tokens.totalOnlyTokens = summary.totalTokens
            }
            fragment.agentSummaries[summary.agentID] = ParsedAgentSummary(
                id: summary.agentID,
                name: summary.name,
                kind: summary.kind,
                status: summary.status,
                timestamp: summary.date,
                usage: usage,
                modelUsage: SessionModelUsage(
                    id: summary.normalizedModel,
                    usage: usage
                ),
                toolCallCount: summary.toolCallCount
            )
        }

        for act in sliceActivities {
            fragment.markSliceActivity(at: act.date, interval: interval)
        }

        if interval == nil {
            fragment.hasActivityInSlice = true
        }

        return fragment
    }
}

final class SessionFragmentCache: @unchecked Sendable {
    static let shared = SessionFragmentCache()

    private struct CacheEntry {
        let mtime: Date
        let fileSize: Int
        let base: BaseSessionFragment
    }

    private var cache: [URL: CacheEntry] = [:]
    private let lock = NSLock()

    func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    func baseFragment(
        for file: URL,
        parse: () -> BaseSessionFragment?
    ) -> BaseSessionFragment? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let mtime = values?.contentModificationDate,
              let fileSize = values?.fileSize else {
            return parse()
        }

        lock.lock()
        if let entry = cache[file], entry.mtime == mtime, entry.fileSize == fileSize {
            let base = entry.base
            lock.unlock()
            return base
        }
        lock.unlock()

        guard let base = parse() else { return nil }

        lock.lock()
        cache[file] = CacheEntry(mtime: mtime, fileSize: fileSize, base: base)
        lock.unlock()

        return base
    }
}

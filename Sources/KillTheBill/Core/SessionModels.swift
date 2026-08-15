import Foundation

enum SessionHarness: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case codex
}

struct UsageSessionID: Hashable, Codable, Sendable {
    let harness: SessionHarness
    let rawValue: String
}

struct SessionTokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheReadTokens: Int = 0

    /// Reasoning tokens are a subset of output tokens and are therefore not added
    /// again when calculating `knownTotalTokens`.
    var reasoningOutputTokens: Int = 0

    /// Some Codex subscription events only expose a total. They remain visible,
    /// but cannot be priced without an input/output breakdown.
    var totalOnlyTokens: Int = 0

    var knownTotalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }

    var reportedTotalTokens: Int { knownTotalTokens + totalOnlyTokens }

    mutating func merge(_ other: SessionTokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheWriteTokens += other.cacheWriteTokens
        cacheReadTokens += other.cacheReadTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalOnlyTokens += other.totalOnlyTokens
    }
}

struct SessionUsage: Codable, Equatable, Sendable {
    var tokens: SessionTokenUsage = SessionTokenUsage()
    var pricedCostUSD: Double = 0
    var modelInvocationCount: Int = 0
    var unpricedModelInvocationCount: Int = 0

    var pricedModelInvocationCount: Int {
        max(modelInvocationCount - unpricedModelInvocationCount, 0)
    }

    var isCostPartial: Bool { unpricedModelInvocationCount > 0 }

    var isCostUnavailable: Bool {
        modelInvocationCount > 0 && pricedModelInvocationCount == 0
    }

    /// `nil` means every invocation was unpriced. A partially known cost returns
    /// its priced portion and exposes that fact through `isCostPartial`.
    var costUSD: Double? {
        if modelInvocationCount == 0 { return 0 }
        return isCostUnavailable ? nil : pricedCostUSD
    }

    mutating func merge(_ other: SessionUsage) {
        tokens.merge(other.tokens)
        pricedCostUSD += other.pricedCostUSD
        modelInvocationCount += other.modelInvocationCount
        unpricedModelInvocationCount += other.unpricedModelInvocationCount
    }
}

enum SessionMetricQuality: String, Codable, Sendable {
    case exact
    case estimated
    case partialEstimate
    case unavailable
}

/// Tool result token counts are not present in either transcript format. This
/// value is deliberately labelled as an estimate derived from textual payloads.
struct SessionResultTokenEstimate: Codable, Equatable, Sendable {
    var value: Int = 0
    var estimatedResultCount: Int = 0
    var unavailableResultCount: Int = 0

    var quality: SessionMetricQuality {
        if estimatedResultCount == 0 { return .unavailable }
        if unavailableResultCount > 0 { return .partialEstimate }
        return .estimated
    }

    mutating func merge(_ other: SessionResultTokenEstimate) {
        value += other.value
        estimatedResultCount += other.estimatedResultCount
        unavailableResultCount += other.unavailableResultCount
    }
}

struct SessionModelUsage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var usage: SessionUsage
}

struct SessionToolUsage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var callCount: Int
    var errorCount: Int
    var resultTokens: SessionResultTokenEstimate
}

struct SessionMCPUsage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var server: String
    var tool: String
    var callCount: Int
    var errorCount: Int
    var resultTokens: SessionResultTokenEstimate
}

enum SessionDataCompleteness: String, Codable, Sendable {
    case complete
    case partial
    case summaryOnly
}

struct SessionSubagentUsage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String?
    var kind: String?
    var status: String?
    var startedAt: Date?
    var lastActivityAt: Date?
    var ownUsage: SessionUsage
    var inclusiveUsage: SessionUsage
    var toolCallCount: Int
    var mcpCallCount: Int
    var tools: [SessionToolUsage]
    var mcps: [SessionMCPUsage]
    var models: [SessionModelUsage]
    var children: [SessionSubagentUsage]
    var dataCompleteness: SessionDataCompleteness
}

struct UsageSession: Identifiable, Codable, Equatable, Sendable {
    let id: UsageSessionID
    var title: String?
    var preview: String
    var repositoryPath: String?
    var repositoryName: String
    var gitBranch: String?
    var startedAt: Date?
    var lastActivityAt: Date?
    var ownUsage: SessionUsage
    var inclusiveUsage: SessionUsage

    /// Explicit user prompts in the root conversation. This is intentionally
    /// separate from model invocations, which include tool-loop continuations.
    var humanTurnCount: Int

    /// Includes built-in tools and MCP calls across the root and all descendants.
    var toolCallCount: Int
    var mcpCallCount: Int
    var tools: [SessionToolUsage]
    var mcps: [SessionMCPUsage]
    var models: [SessionModelUsage]
    var subagents: [SessionSubagentUsage]
    var dataCompleteness: SessionDataCompleteness

    var harness: SessionHarness { id.harness }
    var modelInvocationCount: Int { inclusiveUsage.modelInvocationCount }
}

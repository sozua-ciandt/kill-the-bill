import Foundation

typealias SessionJSONObject = [String: Any]

enum SessionJSONLineReader {
    static func forEachObject(at url: URL, _ body: (SessionJSONObject) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        let newline: UInt8 = 0x0A

        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: newline) {
                let line = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                decode(line, body)
            }
        }

        if !buffer.isEmpty {
            decode(buffer, body)
        }
    }

    private static func decode(_ data: Data, _ body: (SessionJSONObject) -> Void) {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? SessionJSONObject else {
            return
        }
        body(dictionary)
    }
}

func sessionObject(_ value: Any?) -> SessionJSONObject? {
    value as? SessionJSONObject
}

func sessionArray(_ value: Any?) -> [Any]? {
    value as? [Any]
}

func sessionString(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
}

func sessionInt(_ value: Any?) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return 0
}

func sessionBool(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return false
}

func sessionDate(_ value: Any?) -> Date? {
    guard let string = sessionString(value) else { return nil }
    return ParserHelpers.parseISO8601(string)
}

func sessionIncludes(_ date: Date?, in interval: DateInterval?) -> Bool {
    guard let interval else { return true }
    guard let date else { return false }
    return date >= interval.start && date < interval.end
}

func sessionFileModificationDate(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

func sessionRepositoryName(path: String?, fallback: String) -> String {
    guard let path, !path.isEmpty else { return fallback }
    let component = URL(fileURLWithPath: path).lastPathComponent
    return component.isEmpty ? path : component
}

func sanitizedSessionPreview(_ raw: String?, limit: Int = 180) -> String? {
    guard var value = raw, !value.isEmpty else { return nil }

    let removableBlocks = [
        #"<environment_context>[\s\S]*?</environment_context>"#,
        #"<permissions instructions>[\s\S]*?</permissions instructions>"#
    ]
    for pattern in removableBlocks {
        value = value.replacingOccurrences(
            of: pattern,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    value = value
        .unicodeScalars
        .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
        .joined()
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !value.isEmpty else { return nil }
    guard value.count > limit else { return value }
    return String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
}

private struct PayloadTokenEstimate {
    var utf8Bytes: Int = 0
    var hasTextualPayload: Bool = false
    var unavailablePartCount: Int = 0

    mutating func merge(_ other: PayloadTokenEstimate) {
        utf8Bytes += other.utf8Bytes
        hasTextualPayload = hasTextualPayload || other.hasTextualPayload
        unavailablePartCount += other.unavailablePartCount
    }
}

func estimatedSessionResultTokens(from payload: Any?) -> SessionResultTokenEstimate {
    let payloadEstimate = inspectSessionPayload(payload)
    let hasEstimate = payloadEstimate.hasTextualPayload
    let tokenCount = hasEstimate ? Int(ceil(Double(payloadEstimate.utf8Bytes) / 4.0)) : 0

    return SessionResultTokenEstimate(
        value: tokenCount,
        estimatedResultCount: hasEstimate ? 1 : 0,
        unavailableResultCount: payloadEstimate.unavailablePartCount + (hasEstimate ? 0 : 1)
    )
}

private func inspectSessionPayload(_ payload: Any?) -> PayloadTokenEstimate {
    guard let payload, !(payload is NSNull) else {
        return PayloadTokenEstimate(hasTextualPayload: true)
    }

    if let string = payload as? String {
        return PayloadTokenEstimate(
            utf8Bytes: string.lengthOfBytes(using: .utf8),
            hasTextualPayload: true
        )
    }

    if let array = payload as? [Any] {
        return array.reduce(into: PayloadTokenEstimate()) { result, element in
            result.merge(inspectSessionPayload(element))
        }
    }

    if let object = payload as? SessionJSONObject {
        let type = sessionString(object["type"])?.lowercased()
        if ["image", "input_image", "document", "audio", "input_audio"].contains(type) {
            return PayloadTokenEstimate(unavailablePartCount: 1)
        }

        if let text = object["text"] as? String {
            return inspectSessionPayload(text)
        }
        if object["content"] != nil {
            return inspectSessionPayload(object["content"])
        }
        if object["output"] != nil {
            return inspectSessionPayload(object["output"])
        }

        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return PayloadTokenEstimate(utf8Bytes: data.count, hasTextualPayload: true)
        }
    }

    return PayloadTokenEstimate(unavailablePartCount: 1)
}

struct ParsedSessionToolCall {
    let id: String
    var name: String
    var mcpServer: String?
    var mcpTool: String?
    var isError: Bool = false
    var resultTokens: SessionResultTokenEstimate?
}

struct ParsedAgentSummary {
    let id: String
    var name: String?
    var kind: String?
    var status: String?
    var timestamp: Date?
    var usage: SessionUsage
    var modelUsage: SessionModelUsage?
    var toolCallCount: Int
}

struct ParsedSessionFragment {
    let harness: SessionHarness
    var id: String
    var parentID: String? = nil
    var isSubagent: Bool
    var name: String? = nil
    var kind: String? = nil
    var status: String? = nil
    var title: String? = nil
    var preview: String? = nil
    var repositoryPath: String? = nil
    var repositoryFallbackName: String
    var gitBranch: String? = nil
    var startedAt: Date? = nil
    var lastActivityAt: Date? = nil
    var ownUsage = SessionUsage()
    var modelUsages: [String: SessionUsage] = [:]
    var humanTurnIDs: Set<String> = []
    var anonymousHumanTurnCount: Int = 0
    var toolCalls: [String: ParsedSessionToolCall] = [:]
    var reportedToolCallCount: Int = 0
    var spawnedAgentIDs: Set<String> = []
    var agentSummaries: [String: ParsedAgentSummary] = [:]
    var hasActivityInSlice: Bool = false
    var dataCompleteness: SessionDataCompleteness = .complete

    var humanTurnCount: Int { humanTurnIDs.count + anonymousHumanTurnCount }

    mutating func observeLifetimeDate(_ date: Date?) {
        guard let date else { return }
        if startedAt == nil || date < startedAt! { startedAt = date }
        if lastActivityAt == nil || date > lastActivityAt! { lastActivityAt = date }
    }

    mutating func markSliceActivity(at date: Date?, interval: DateInterval?) {
        if sessionIncludes(date, in: interval) { hasActivityInSlice = true }
    }

    mutating func addHumanTurn(id: String?, at date: Date?, interval: DateInterval?) {
        guard sessionIncludes(date, in: interval) else { return }
        hasActivityInSlice = true
        if let id { humanTurnIDs.insert(id) } else { anonymousHumanTurnCount += 1 }
    }

    mutating func addInvocation(
        model: String,
        tokens: SessionTokenUsage,
        costUSD: Double?,
        at date: Date?,
        interval: DateInterval?
    ) {
        guard sessionIncludes(date, in: interval) else { return }
        hasActivityInSlice = true

        ownUsage.tokens.merge(tokens)
        ownUsage.modelInvocationCount += 1
        if let costUSD {
            ownUsage.pricedCostUSD += costUSD
        } else {
            ownUsage.unpricedModelInvocationCount += 1
        }

        var modelUsage = modelUsages[model] ?? SessionUsage()
        modelUsage.tokens.merge(tokens)
        modelUsage.modelInvocationCount += 1
        if let costUSD {
            modelUsage.pricedCostUSD += costUSD
        } else {
            modelUsage.unpricedModelInvocationCount += 1
        }
        modelUsages[model] = modelUsage
    }

    mutating func addToolCall(
        id: String,
        name: String,
        mcpServer: String? = nil,
        mcpTool: String? = nil,
        at date: Date?,
        interval: DateInterval?
    ) {
        guard sessionIncludes(date, in: interval) else { return }
        hasActivityInSlice = true

        if var existing = toolCalls[id] {
            existing.name = name
            existing.mcpServer = mcpServer ?? existing.mcpServer
            existing.mcpTool = mcpTool ?? existing.mcpTool
            toolCalls[id] = existing
        } else {
            toolCalls[id] = ParsedSessionToolCall(
                id: id,
                name: name,
                mcpServer: mcpServer,
                mcpTool: mcpTool
            )
        }
    }

    mutating func addToolResult(
        callID: String,
        payload: Any?,
        isError: Bool,
        at date: Date?,
        interval: DateInterval?
    ) {
        guard sessionIncludes(date, in: interval), var call = toolCalls[callID] else { return }
        call.isError = call.isError || isError
        if call.resultTokens == nil {
            call.resultTokens = estimatedSessionResultTokens(from: payload)
        }
        toolCalls[callID] = call
    }
}

struct ParsedSessionAggregate {
    var usage = SessionUsage()
    var modelUsages: [String: SessionUsage] = [:]
    var toolCalls: [String: ParsedSessionToolCall] = [:]
    var reportedToolCallCount: Int = 0
    var completeness: SessionDataCompleteness = .complete

    mutating func merge(_ other: ParsedSessionAggregate, keyPrefix: String) {
        usage.merge(other.usage)
        mergeSessionModelUsages(&modelUsages, other.modelUsages)
        for (id, call) in other.toolCalls {
            toolCalls["\(keyPrefix):\(id)"] = call
        }
        reportedToolCallCount += other.reportedToolCallCount
        if other.completeness != .complete { completeness = .partial }
    }
}

func mergeSessionModelUsages(_ target: inout [String: SessionUsage], _ source: [String: SessionUsage]) {
    for (model, usage) in source {
        var existing = target[model] ?? SessionUsage()
        existing.merge(usage)
        target[model] = existing
    }
}

func sessionModelList(from usages: [String: SessionUsage]) -> [SessionModelUsage] {
    usages.map { SessionModelUsage(id: $0.key, usage: $0.value) }
        .sorted {
            if $0.usage.pricedCostUSD == $1.usage.pricedCostUSD,
               $0.usage.modelInvocationCount == $1.usage.modelInvocationCount {
                return $0.id < $1.id
            }
            if $0.usage.pricedCostUSD == $1.usage.pricedCostUSD {
                return $0.usage.modelInvocationCount > $1.usage.modelInvocationCount
            }
            return $0.usage.pricedCostUSD > $1.usage.pricedCostUSD
        }
}

func sessionToolLists(
    from calls: [String: ParsedSessionToolCall]
) -> (tools: [SessionToolUsage], mcps: [SessionMCPUsage]) {
    var tools: [String: SessionToolUsage] = [:]
    var mcps: [String: SessionMCPUsage] = [:]

    for call in calls.values {
        let estimate = call.resultTokens ?? SessionResultTokenEstimate(unavailableResultCount: 1)
        if var tool = tools[call.name] {
            tool.callCount += 1
            if call.isError { tool.errorCount += 1 }
            tool.resultTokens.merge(estimate)
            tools[call.name] = tool
        } else {
            tools[call.name] = SessionToolUsage(
                id: call.name,
                name: call.name,
                callCount: 1,
                errorCount: call.isError ? 1 : 0,
                resultTokens: estimate
            )
        }

        if let server = call.mcpServer, let toolName = call.mcpTool {
            let id = "\(server)::\(toolName)"
            if var mcp = mcps[id] {
                mcp.callCount += 1
                if call.isError { mcp.errorCount += 1 }
                mcp.resultTokens.merge(estimate)
                mcps[id] = mcp
            } else {
                mcps[id] = SessionMCPUsage(
                    id: id,
                    server: server,
                    tool: toolName,
                    callCount: 1,
                    errorCount: call.isError ? 1 : 0,
                    resultTokens: estimate
                )
            }
        }
    }

    let toolList = tools.values.sorted {
        if $0.callCount == $1.callCount { return $0.name < $1.name }
        return $0.callCount > $1.callCount
    }
    let mcpList = mcps.values.sorted {
        if $0.callCount == $1.callCount { return $0.id < $1.id }
        return $0.callCount > $1.callCount
    }
    return (toolList, mcpList)
}

func sessionMCPIdentity(fromClaudeToolName name: String) -> (server: String, tool: String)? {
    guard name.hasPrefix("mcp__") else { return nil }
    let components = String(name.dropFirst("mcp__".count)).components(separatedBy: "__")
    guard components.count >= 2, let server = components.first else { return nil }
    return (server, components.dropFirst().joined(separator: "__"))
}

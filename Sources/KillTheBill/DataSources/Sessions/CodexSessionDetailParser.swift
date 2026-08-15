import Foundation

enum CodexSessionDetailParser {
    static func parseFragments(
        files: [URL],
        pricing: ModelPricing,
        interval: DateInterval?
    ) -> [ParsedSessionFragment] {
        files.map { parseFile($0, pricing: pricing, interval: interval) }
    }

    private static func parseFile(
        _ file: URL,
        pricing: ModelPricing,
        interval: DateInterval?
    ) -> ParsedSessionFragment {
        var fragment = ParsedSessionFragment(
            harness: .codex,
            id: file.deletingPathExtension().lastPathComponent,
            isSubagent: false,
            repositoryFallbackName: "Codex"
        )
        var currentModel = "unknown"
        var anonymousToolIndex = 0
        var anonymousTurnIndex = 0
        var hasCanonicalSessionMetadata = false
        var ownHistoryStartOrdinal: Int?

        SessionJSONLineReader.forEachObject(at: file) { entry in
            let entryType = sessionString(entry["type"])
            let payload = sessionObject(entry["payload"]) ?? [:]
            let payloadType = sessionString(payload["type"])
            let date = sessionDate(entry["timestamp"])

            if entryType == "session_meta" {
                // Forked/subagent rollouts can embed the parent's session metadata
                // after their own. The first record describes this file; later ones
                // are inherited context and must not replace its identity.
                guard !hasCanonicalSessionMetadata else { return }
                hasCanonicalSessionMetadata = true
                ownHistoryStartOrdinal = optionalSessionInt(payload["subagent_history_start_ordinal"])

                fragment.id = sessionString(payload["id"])
                    ?? sessionString(payload["session_id"])
                    ?? fragment.id
                fragment.parentID = sessionString(payload["parent_thread_id"])
                fragment.repositoryPath = sessionString(payload["cwd"]) ?? fragment.repositoryPath
                fragment.repositoryFallbackName = sessionRepositoryName(
                    path: fragment.repositoryPath,
                    fallback: "Codex"
                )
                fragment.name = sessionString(payload["agent_nickname"])
                fragment.kind = codexSubagentKind(from: payload)

                if let threadSource = sessionString(payload["thread_source"]) {
                    fragment.isSubagent = threadSource == "subagent"
                } else {
                    fragment.isSubagent = fragment.parentID != nil
                }

                if let git = sessionObject(payload["git"]) {
                    fragment.gitBranch = sessionString(git["branch"])
                }
                fragment.observeLifetimeDate(date)
                fragment.observeLifetimeDate(sessionDate(payload["timestamp"]))
                return
            }

            if let firstOwnOrdinal = ownHistoryStartOrdinal,
               let ordinal = optionalSessionInt(entry["ordinal"]),
               ordinal < firstOwnOrdinal {
                return
            }

            fragment.observeLifetimeDate(date)

            switch entryType {
            case "turn_context":
                currentModel = sessionString(payload["model"]) ?? currentModel
                fragment.repositoryPath = sessionString(payload["cwd"]) ?? fragment.repositoryPath
                fragment.repositoryFallbackName = sessionRepositoryName(
                    path: fragment.repositoryPath,
                    fallback: fragment.repositoryFallbackName
                )

            case "event_msg":
                switch payloadType {
                case "user_message":
                    guard !fragment.isSubagent else { break }
                    anonymousTurnIndex += 1
                    let text = sessionString(payload["message"])
                    let turnID = sessionString(payload["client_id"])
                        ?? sessionString(entry["ordinal"])
                        ?? "user-\(anonymousTurnIndex)"
                    fragment.addHumanTurn(id: turnID, at: date, interval: interval)
                    if fragment.preview == nil {
                        fragment.preview = sanitizedSessionPreview(text)
                    }

                case "task_started":
                    fragment.markSliceActivity(at: date, interval: interval)

                case "task_complete":
                    fragment.status = "completed"
                    fragment.markSliceActivity(at: date, interval: interval)

                case "turn_aborted":
                    fragment.status = "aborted"
                    fragment.markSliceActivity(at: date, interval: interval)

                case "token_count":
                    guard let info = sessionObject(payload["info"]),
                          let usageObject = sessionObject(info["last_token_usage"]) else {
                        break
                    }
                    let tokens = codexTokens(from: usageObject)
                    let hasDetailedUsage = tokens.knownTotalTokens > 0
                    let cost = hasDetailedUsage
                        ? pricing.cost(
                            model: currentModel,
                            input: tokens.inputTokens,
                            output: tokens.outputTokens,
                            cacheWrite: tokens.cacheWriteTokens,
                            cacheRead: tokens.cacheReadTokens
                        )
                        : nil
                    fragment.addInvocation(
                        model: ModelPricing.normalizeProviderModel(currentModel),
                        tokens: tokens,
                        costUSD: cost,
                        at: date,
                        interval: interval
                    )

                case "mcp_tool_call_end":
                    guard let invocation = sessionObject(payload["invocation"]),
                          let server = sessionString(invocation["server"]),
                          let tool = sessionString(invocation["tool"]) else {
                        break
                    }
                    anonymousToolIndex += 1
                    let callID = sessionString(payload["call_id"])
                        ?? "mcp-\(anonymousToolIndex)"
                    let name = "mcp__\(server)__\(tool)"
                    fragment.addToolCall(
                        id: callID,
                        name: name,
                        mcpServer: server,
                        mcpTool: tool,
                        at: date,
                        interval: interval
                    )

                    let result = sessionObject(payload["result"])
                    let ok = result?["Ok"]
                    let error = result?["Err"]
                    fragment.addToolResult(
                        callID: callID,
                        payload: ok ?? error ?? payload["result"],
                        isError: error != nil,
                        at: date,
                        interval: interval
                    )

                default:
                    break
                }

            case "response_item":
                switch payloadType {
                case "function_call", "custom_tool_call":
                    guard let name = sessionString(payload["name"]) else { break }
                    anonymousToolIndex += 1
                    let callID = sessionString(payload["call_id"])
                        ?? sessionString(payload["id"])
                        ?? "tool-\(anonymousToolIndex)"
                    let mcp = sessionMCPIdentity(fromClaudeToolName: name)
                    fragment.addToolCall(
                        id: callID,
                        name: name,
                        mcpServer: mcp?.server,
                        mcpTool: mcp?.tool,
                        at: date,
                        interval: interval
                    )

                case "function_call_output", "custom_tool_call_output":
                    guard let callID = sessionString(payload["call_id"]) else { break }
                    fragment.addToolResult(
                        callID: callID,
                        payload: payload["output"],
                        isError: codexOutputIsError(payload["output"]),
                        at: date,
                        interval: interval
                    )

                case "web_search_call":
                    anonymousToolIndex += 1
                    let callID = sessionString(payload["call_id"])
                        ?? sessionString(payload["id"])
                        ?? "web-search-\(anonymousToolIndex)"
                    fragment.addToolCall(
                        id: callID,
                        name: "web_search",
                        at: date,
                        interval: interval
                    )

                default:
                    break
                }

            default:
                break
            }
        }

        if fragment.startedAt == nil, let fallbackDate = sessionFileModificationDate(file) {
            fragment.startedAt = fallbackDate
            fragment.lastActivityAt = fallbackDate
        }
        return fragment
    }

    private static func optionalSessionInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func codexTokens(from usage: SessionJSONObject) -> SessionTokenUsage {
        let rawInput = sessionInt(usage["input_tokens"])
        let cacheRead = min(rawInput, sessionInt(usage["cached_input_tokens"]))
        let remainingAfterRead = max(rawInput - cacheRead, 0)
        let cacheWrite = min(remainingAfterRead, sessionInt(usage["cache_write_input_tokens"]))
        let input = max(remainingAfterRead - cacheWrite, 0)
        let output = sessionInt(usage["output_tokens"])
        let knownTotal = rawInput + output
        let reportedTotal = sessionInt(usage["total_tokens"])
        let totalOnly = knownTotal == 0 ? reportedTotal : 0

        return SessionTokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheWriteTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            reasoningOutputTokens: min(output, sessionInt(usage["reasoning_output_tokens"])),
            totalOnlyTokens: totalOnly
        )
    }

    private static func codexSubagentKind(from payload: SessionJSONObject) -> String? {
        guard let source = sessionObject(payload["source"]),
              let subagent = sessionObject(source["subagent"]) else {
            return nil
        }
        return sessionString(subagent["agent_role"])
            ?? sessionString(subagent["type"])
            ?? sessionString(subagent["kind"])
    }

    private static func codexOutputIsError(_ output: Any?) -> Bool {
        guard let output else { return false }
        if let object = sessionObject(output) {
            return sessionBool(object["isError"])
                || sessionBool(object["is_error"])
                || object["Err"] != nil
        }
        if let string = output as? String,
           let data = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data),
           let object = decoded as? SessionJSONObject {
            return sessionBool(object["isError"])
                || sessionBool(object["is_error"])
                || object["Err"] != nil
        }
        return false
    }
}

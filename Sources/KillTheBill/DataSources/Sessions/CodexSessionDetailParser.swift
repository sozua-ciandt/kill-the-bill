import Foundation

enum CodexSessionDetailParser {
    static func parseFragments(
        files: [URL],
        pricing: ModelPricing,
        interval: DateInterval?
    ) -> [ParsedSessionFragment] {
        files.compactMap { file in
            let base = SessionFragmentCache.shared.baseFragment(for: file) {
                parseFile(file)
            }
            return base?.slice(pricing: pricing, interval: interval)
        }
    }

    private static func parseFile(
        _ file: URL
    ) -> BaseSessionFragment {
        var base = BaseSessionFragment(
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

                base.id = sessionString(payload["id"])
                    ?? sessionString(payload["session_id"])
                    ?? base.id
                base.parentID = sessionString(payload["parent_thread_id"])
                base.repositoryPath = sessionString(payload["cwd"]) ?? base.repositoryPath
                base.repositoryFallbackName = sessionRepositoryName(
                    path: base.repositoryPath,
                    fallback: "Codex"
                )
                base.name = sessionString(payload["agent_nickname"])
                base.kind = codexSubagentKind(from: payload)

                if let threadSource = sessionString(payload["thread_source"]) {
                    base.isSubagent = threadSource == "subagent"
                } else {
                    base.isSubagent = base.parentID != nil
                }

                if let git = sessionObject(payload["git"]) {
                    base.gitBranch = sessionString(git["branch"])
                }
                base.observeLifetimeDate(date)
                base.observeLifetimeDate(sessionDate(payload["timestamp"]))
                return
            }

            if let firstOwnOrdinal = ownHistoryStartOrdinal,
               let ordinal = optionalSessionInt(entry["ordinal"]),
               ordinal < firstOwnOrdinal {
                return
            }

            base.observeLifetimeDate(date)

            switch entryType {
            case "turn_context":
                currentModel = sessionString(payload["model"]) ?? currentModel
                base.repositoryPath = sessionString(payload["cwd"]) ?? base.repositoryPath
                base.repositoryFallbackName = sessionRepositoryName(
                    path: base.repositoryPath,
                    fallback: base.repositoryFallbackName
                )

            case "event_msg":
                switch payloadType {
                case "user_message":
                    guard !base.isSubagent else { break }
                    anonymousTurnIndex += 1
                    let text = sessionString(payload["message"])
                    let turnID = sessionString(payload["client_id"])
                        ?? sessionString(entry["ordinal"])
                        ?? "user-\(anonymousTurnIndex)"
                    base.humanTurns.append(
                        BaseSessionEventHumanTurn(id: turnID, date: date)
                    )
                    if base.preview == nil {
                        base.preview = sanitizedSessionPreview(text)
                    }

                case "task_started":
                    base.sliceActivities.append(BaseSessionEventSliceActivity(date: date))

                case "task_complete":
                    base.status = "completed"
                    base.sliceActivities.append(BaseSessionEventSliceActivity(date: date))

                case "turn_aborted":
                    base.status = "aborted"
                    base.sliceActivities.append(BaseSessionEventSliceActivity(date: date))

                case "token_count":
                    guard let info = sessionObject(payload["info"]),
                          let usageObject = sessionObject(info["last_token_usage"]) else {
                        break
                    }
                    let tokens = codexTokens(from: usageObject)
                    base.invocations.append(
                        BaseSessionEventInvocation(
                            rawModel: currentModel,
                            normalizedModel: ModelPricing.normalizeProviderModel(currentModel),
                            tokens: tokens,
                            date: date
                        )
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
                    base.toolCalls.append(
                        BaseSessionEventToolCall(
                            id: callID,
                            name: name,
                            mcpServer: server,
                            mcpTool: tool,
                            date: date
                        )
                    )

                    let result = sessionObject(payload["result"])
                    let ok = result?["Ok"]
                    let error = result?["Err"]
                    let payloadEstimate = estimatedSessionResultTokens(from: ok ?? error ?? payload["result"])
                    base.toolResults.append(
                        BaseSessionEventToolResult(
                            callID: callID,
                            payloadEstimate: payloadEstimate,
                            isError: error != nil,
                            date: date
                        )
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
                    base.toolCalls.append(
                        BaseSessionEventToolCall(
                            id: callID,
                            name: name,
                            mcpServer: mcp?.server,
                            mcpTool: mcp?.tool,
                            date: date
                        )
                    )

                case "function_call_output", "custom_tool_call_output":
                    guard let callID = sessionString(payload["call_id"]) else { break }
                    let payloadEstimate = estimatedSessionResultTokens(from: payload["output"])
                    base.toolResults.append(
                        BaseSessionEventToolResult(
                            callID: callID,
                            payloadEstimate: payloadEstimate,
                            isError: codexOutputIsError(payload["output"]),
                            date: date
                        )
                    )

                case "web_search_call":
                    anonymousToolIndex += 1
                    let callID = sessionString(payload["call_id"])
                        ?? sessionString(payload["id"])
                        ?? "web-search-\(anonymousToolIndex)"
                    base.toolCalls.append(
                        BaseSessionEventToolCall(
                            id: callID,
                            name: "web_search",
                            mcpServer: nil,
                            mcpTool: nil,
                            date: date
                        )
                    )

                default:
                    break
                }

            default:
                break
            }
        }

        if base.startedAt == nil, let fallbackDate = sessionFileModificationDate(file) {
            base.startedAt = fallbackDate
            base.lastActivityAt = fallbackDate
        }
        return base
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

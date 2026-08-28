import Foundation

enum ClaudeSessionDetailParser {
    static func parseFragments(
        transcriptDirs: [URL],
        files: [URL],
        pricing: ModelPricing,
        interval: DateInterval?
    ) -> [ParsedSessionFragment] {
        files.compactMap { file in
            let base = SessionFragmentCache.shared.baseFragment(for: file) {
                parseFile(
                    file,
                    identity: fileIdentity(for: file, transcriptDirs: transcriptDirs)
                )
            }
            return base?.slice(pricing: pricing, interval: interval)
        }
    }

    private struct FileIdentity {
        let id: String
        let rootID: String
        let isSubagent: Bool
        let projectName: String
    }

    private static func fileIdentity(for file: URL, transcriptDirs: [URL]) -> FileIdentity {
        let standardized = file.standardizedFileURL
        let components = standardized.pathComponents

        if let subagentsIndex = components.lastIndex(of: "subagents"), subagentsIndex > 0 {
            let rootID = components[subagentsIndex - 1]
            var agentID = standardized.deletingPathExtension().lastPathComponent
            if agentID.hasPrefix("agent-") { agentID.removeFirst("agent-".count) }
            return FileIdentity(
                id: agentID,
                rootID: rootID,
                isSubagent: true,
                projectName: projectName(for: file, transcriptDirs: transcriptDirs)
            )
        }

        let rootID = standardized.deletingPathExtension().lastPathComponent
        return FileIdentity(
            id: rootID,
            rootID: rootID,
            isSubagent: false,
            projectName: projectName(for: file, transcriptDirs: transcriptDirs)
        )
    }

    private static func projectName(for file: URL, transcriptDirs: [URL]) -> String {
        let filePath = file.standardizedFileURL.path
        for directory in transcriptDirs {
            let directoryPath = directory.standardizedFileURL.path
            if filePath == directoryPath || filePath.hasPrefix(directoryPath + "/") {
                return decodedProjectName(from: directory.lastPathComponent)
            }
        }

        let components = file.standardizedFileURL.pathComponents
        if let subagentsIndex = components.lastIndex(of: "subagents"), subagentsIndex >= 2 {
            return decodedProjectName(from: components[subagentsIndex - 2])
        }
        return decodedProjectName(from: file.deletingLastPathComponent().lastPathComponent)
    }

    private static func decodedProjectName(from directoryName: String) -> String {
        let knownParents = Set([
            "Users", "Projetos", "Projects", "Developer", "Code", "dev", "repos",
            "src", "workspace", "home", "tmp", "ProjectsAlt"
        ])
        let parts = directoryName.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        guard let parentIndex = parts.lastIndex(where: { knownParents.contains($0) }) else {
            return directoryName
        }

        var projectStart = parentIndex + 1
        if ["Users", "home"].contains(parts[parentIndex]), projectStart < parts.count {
            projectStart += 1
        }
        guard projectStart < parts.count else { return directoryName }
        return parts[projectStart...].joined(separator: "-")
    }

    private static func parseFile(
        _ file: URL,
        identity: FileIdentity
    ) -> BaseSessionFragment {
        var base = BaseSessionFragment(
            harness: .claudeCode,
            id: identity.id,
            parentID: identity.isSubagent ? identity.rootID : nil,
            isSubagent: identity.isSubagent,
            repositoryFallbackName: identity.projectName
        )

        var seenUsageIDs: Set<String> = []
        var seenToolIDs: Set<String> = []
        var anonymousUsageIndex = 0
        var anonymousToolIndex = 0
        var lastPromptCandidate: String?

        SessionJSONLineReader.forEachObject(at: file) { entry in
            let type = sessionString(entry["type"])
            let date = sessionDate(entry["timestamp"])
            base.observeLifetimeDate(date)

            if base.repositoryPath == nil {
                base.repositoryPath = sessionString(entry["cwd"])
            }
            if base.gitBranch == nil {
                base.gitBranch = sessionString(entry["gitBranch"])
            }
            if base.isSubagent, base.name == nil {
                base.name = sessionString(entry["attributionAgent"])
            }

            switch type {
            case "ai-title":
                if base.title == nil {
                    base.title = sanitizedSessionPreview(sessionString(entry["aiTitle"]), limit: 100)
                }

            case "last-prompt":
                lastPromptCandidate = sanitizedSessionPreview(sessionString(entry["lastPrompt"]))

            case "assistant":
                guard let message = sessionObject(entry["message"]) else { return }
                let messageID = sessionString(message["id"])
                let entryUUID = sessionString(entry["uuid"])

                if let usageObject = sessionObject(message["usage"]) {
                    anonymousUsageIndex += 1
                    let usageID = messageID ?? entryUUID ?? "usage-\(anonymousUsageIndex)"
                    if seenUsageIDs.insert(usageID).inserted {
                        let rawModel = sessionString(message["model"]) ?? "unknown"
                        let tokens = claudeTokens(from: usageObject)
                        base.invocations.append(
                            BaseSessionEventInvocation(
                                rawModel: rawModel,
                                normalizedModel: ModelPricing.normalizeModel(rawModel),
                                tokens: tokens,
                                date: date
                            )
                        )
                    }
                }

                guard let content = sessionArray(message["content"]) else { return }
                for (index, rawBlock) in content.enumerated() {
                    guard let block = sessionObject(rawBlock),
                          sessionString(block["type"]) == "tool_use",
                          let name = sessionString(block["name"]) else {
                        continue
                    }

                    anonymousToolIndex += 1
                    let toolID = sessionString(block["id"])
                        ?? "\(messageID ?? entryUUID ?? "message")-tool-\(index)-\(anonymousToolIndex)"
                    guard seenToolIDs.insert(toolID).inserted else { continue }
                    let mcp = sessionMCPIdentity(fromClaudeToolName: name)
                    base.toolCalls.append(
                        BaseSessionEventToolCall(
                            id: toolID,
                            name: name,
                            mcpServer: mcp?.server,
                            mcpTool: mcp?.tool,
                            date: date
                        )
                    )
                }

            case "user":
                parseUserEntry(
                    entry,
                    date: date,
                    base: &base
                )

            default:
                break
            }
        }

        if base.preview == nil { base.preview = lastPromptCandidate }
        if base.startedAt == nil, let fallbackDate = sessionFileModificationDate(file) {
            base.startedAt = fallbackDate
            base.lastActivityAt = fallbackDate
        }
        return base
    }

    private static func parseUserEntry(
        _ entry: SessionJSONObject,
        date: Date?,
        base: inout BaseSessionFragment
    ) {
        guard let message = sessionObject(entry["message"]) else { return }
        let isMeta = sessionBool(entry["isMeta"])
        let content = message["content"]
        var humanText: String?
        var hasHumanContent = false

        if let string = content as? String {
            humanText = sanitizedSessionPreview(string)
            hasHumanContent = humanText != nil
        } else if let blocks = sessionArray(content) {
            var textParts: [String] = []
            for rawBlock in blocks {
                guard let block = sessionObject(rawBlock) else { continue }
                switch sessionString(block["type"]) {
                case "tool_result":
                    guard let callID = sessionString(block["tool_use_id"]) else { continue }
                    let payloadEstimate = estimatedSessionResultTokens(from: block["content"])
                    base.toolResults.append(
                        BaseSessionEventToolResult(
                            callID: callID,
                            payloadEstimate: payloadEstimate,
                            isError: sessionBool(block["is_error"]),
                            date: date
                        )
                    )
                case "text":
                    if let text = sessionString(block["text"]) { textParts.append(text) }
                case "image", "document":
                    hasHumanContent = true
                default:
                    break
                }
            }
            humanText = sanitizedSessionPreview(textParts.joined(separator: " "))
            hasHumanContent = hasHumanContent || humanText != nil
        }

        if !isMeta, hasHumanContent {
            let turnID = sessionString(entry["promptId"]) ?? sessionString(entry["uuid"])
            base.humanTurns.append(
                BaseSessionEventHumanTurn(
                    id: turnID,
                    date: date
                )
            )
            if base.preview == nil { base.preview = humanText }
        }

        guard let result = sessionObject(entry["toolUseResult"]),
              let agentID = sessionString(result["agentId"])
                ?? sessionString(result["agent_id"]) else {
            return
        }

        base.spawnedAgentIDs.insert(agentID)
        guard let usageObject = sessionObject(result["usage"]) else { return }

        let rawModel = sessionString(result["resolvedModel"])
            ?? sessionString(result["model"])
            ?? "unknown"
        let tokens = claudeTokens(from: usageObject)
        let invocationCount = max(sessionInt(usageObject["iterations"]), 1)
        let totalTokens = (tokens.reportedTotalTokens == 0 && sessionInt(result["totalTokens"]) > 0)
            ? sessionInt(result["totalTokens"])
            : 0

        base.agentSummaries.append(
            BaseSessionEventAgentSummary(
                agentID: agentID,
                name: sessionString(result["description"]),
                kind: sessionString(result["agentType"]),
                status: sessionString(result["status"]),
                date: date,
                rawModel: rawModel,
                normalizedModel: ModelPricing.normalizeModel(rawModel),
                tokens: tokens,
                invocationCount: invocationCount,
                toolCallCount: sessionInt(result["totalToolUseCount"]),
                totalTokens: totalTokens
            )
        )
    }

    private static func claudeTokens(from usage: SessionJSONObject) -> SessionTokenUsage {
        SessionTokenUsage(
            inputTokens: sessionInt(usage["input_tokens"]),
            outputTokens: sessionInt(usage["output_tokens"]),
            cacheWriteTokens: sessionInt(usage["cache_creation_input_tokens"]),
            cacheReadTokens: sessionInt(usage["cache_read_input_tokens"])
        )
    }
}

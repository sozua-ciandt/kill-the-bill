import Foundation

enum SessionLogParser {
    static func parse(
        claudeTranscriptDirs: [URL],
        claudeFiles: [URL],
        codexFiles: [URL],
        opencodeDB: URL? = nil,
        pricing: ModelPricing,
        interval: DateInterval? = nil
    ) -> [UsageSession] {
        let claudeFragments = ClaudeSessionDetailParser.parseFragments(
            transcriptDirs: claudeTranscriptDirs,
            files: claudeFiles,
            pricing: pricing,
            interval: interval
        )
        let codexFragments = CodexSessionDetailParser.parseFragments(
            files: codexFiles,
            pricing: pricing,
            interval: interval
        )
        let opencodeFragments = OpenCodeDBMonitor.parseSessions(
            dbURL: opencodeDB,
            pricing: pricing,
            interval: interval
        )

        return (buildClaudeSessions(from: claudeFragments)
            + buildSessions(from: codexFragments)
            + buildSessions(from: opencodeFragments))
            .sorted {
                switch ($0.lastActivityAt, $1.lastActivityAt) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.id.rawValue < $1.id.rawValue
                }
            }
    }

    // MARK: - Claude relationships

    private static func buildClaudeSessions(
        from parsedFragments: [ParsedSessionFragment]
    ) -> [UsageSession] {
        var fragments: [String: ParsedSessionFragment] = [:]
        for fragment in parsedFragments {
            fragments[fragment.id] = fragment
        }

        // Agent results identify the actual spawning scope, including nested agents.
        // Prefer a child transcript whenever one exists and retain summary usage only
        // as a fallback when that transcript was not discovered.
        for parent in parsedFragments {
            for agentID in parent.spawnedAgentIDs {
                if var child = fragments[agentID] {
                    child.parentID = parent.id
                    child.isSubagent = true
                    if let summary = parent.agentSummaries[agentID] {
                        child.name = child.name ?? summary.name
                        child.kind = child.kind ?? summary.kind
                        child.status = child.status ?? summary.status
                    }
                    fragments[agentID] = child
                } else if let summary = parent.agentSummaries[agentID] {
                    fragments[agentID] = summaryFragment(
                        summary,
                        parent: parent
                    )
                }
            }
        }

        // A caller can pass a subagent file without its root transcript. Preserve the
        // logical session boundary with a lightweight partial root instead of exposing
        // that subagent as an unrelated top-level conversation.
        let missingRootIDs = Set(
            fragments.values.compactMap { fragment -> String? in
                guard fragment.isSubagent,
                      let parentID = fragment.parentID,
                      fragments[parentID] == nil else { return nil }
                return parentID
            }
        )
        for rootID in missingRootIDs {
            guard let child = fragments.values.first(where: { $0.parentID == rootID }) else { continue }
            var root = ParsedSessionFragment(
                harness: .claudeCode,
                id: rootID,
                isSubagent: false,
                repositoryFallbackName: child.repositoryFallbackName
            )
            root.repositoryPath = child.repositoryPath
            root.startedAt = child.startedAt
            root.lastActivityAt = child.lastActivityAt
            root.dataCompleteness = .partial
            fragments[rootID] = root
        }

        return buildSessions(from: Array(fragments.values))
    }

    private static func summaryFragment(
        _ summary: ParsedAgentSummary,
        parent: ParsedSessionFragment
    ) -> ParsedSessionFragment {
        var fragment = ParsedSessionFragment(
            harness: .claudeCode,
            id: summary.id,
            parentID: parent.id,
            isSubagent: true,
            name: summary.name,
            kind: summary.kind,
            status: summary.status,
            repositoryPath: parent.repositoryPath,
            repositoryFallbackName: parent.repositoryFallbackName,
            gitBranch: parent.gitBranch,
            startedAt: summary.timestamp,
            lastActivityAt: summary.timestamp,
            ownUsage: summary.usage,
            reportedToolCallCount: summary.toolCallCount,
            hasActivityInSlice: true,
            dataCompleteness: .summaryOnly
        )
        if let modelUsage = summary.modelUsage {
            fragment.modelUsages[modelUsage.id] = modelUsage.usage
        }
        return fragment
    }

    // MARK: - Graph reduction

    private struct BuiltNode {
        var subagent: SessionSubagentUsage
        var aggregate: ParsedSessionAggregate
        var hasActivityInSlice: Bool
        var startedAt: Date?
        var lastActivityAt: Date?
        var repositoryPath: String?
        var preview: String?
    }

    private static func buildSessions(from fragments: [ParsedSessionFragment]) -> [UsageSession] {
        var byID: [String: ParsedSessionFragment] = [:]
        for var fragment in fragments {
            if fragment.isSubagent,
               let parentID = fragment.parentID,
               !fragments.contains(where: { $0.id == parentID }) {
                fragment.dataCompleteness = .partial
            }
            byID[fragment.id] = fragment
        }

        var children: [String: [String]] = [:]
        for fragment in byID.values {
            if let parentID = fragment.parentID, byID[parentID] != nil {
                children[parentID, default: []].append(fragment.id)
            }
        }
        for key in children.keys {
            children[key]?.sort()
        }

        let roots = byID.values
            .filter { fragment in
                guard let parentID = fragment.parentID else { return true }
                return byID[parentID] == nil
            }
            .sorted { $0.id < $1.id }

        return roots.compactMap { root in
            let childNodes = (children[root.id] ?? []).compactMap {
                buildSubagent(
                    id: $0,
                    fragments: byID,
                    children: children,
                    ancestors: [root.id]
                )
            }

            var aggregate = directAggregate(for: root)
            var hasActivity = root.hasActivityInSlice
            var lastActivity = root.lastActivityAt
            var startedAt = root.startedAt
            var repositoryPath = root.repositoryPath
            var preview = root.preview

            for child in childNodes {
                aggregate.merge(child.aggregate, keyPrefix: child.subagent.id)
                hasActivity = hasActivity || child.hasActivityInSlice
                startedAt = earlierDate(startedAt, child.startedAt)
                lastActivity = laterDate(lastActivity, child.lastActivityAt)
                repositoryPath = repositoryPath ?? child.repositoryPath
                preview = preview ?? child.preview
            }

            guard hasActivity else { return nil }

            let lists = sessionToolLists(from: aggregate.toolCalls)
            let title = root.title
            return UsageSession(
                id: UsageSessionID(harness: root.harness, rawValue: root.id),
                title: title,
                preview: root.preview ?? title ?? preview ?? "",
                repositoryPath: repositoryPath,
                repositoryName: sessionRepositoryName(
                    path: repositoryPath,
                    fallback: root.repositoryFallbackName
                ),
                gitBranch: root.gitBranch,
                startedAt: startedAt,
                lastActivityAt: lastActivity,
                ownUsage: root.ownUsage,
                inclusiveUsage: aggregate.usage,
                humanTurnCount: root.humanTurnCount,
                toolCallCount: aggregate.toolCalls.count + aggregate.reportedToolCallCount,
                mcpCallCount: aggregate.toolCalls.values.filter { $0.mcpServer != nil }.count,
                tools: lists.tools,
                mcps: lists.mcps,
                models: sessionModelList(from: aggregate.modelUsages),
                subagents: childNodes.map(\.subagent),
                dataCompleteness: aggregate.completeness
            )
        }
    }

    private static func buildSubagent(
        id: String,
        fragments: [String: ParsedSessionFragment],
        children: [String: [String]],
        ancestors: Set<String>
    ) -> BuiltNode? {
        guard let fragment = fragments[id] else { return nil }
        var nextAncestors = ancestors
        let inserted = nextAncestors.insert(id).inserted

        let childNodes: [BuiltNode]
        if inserted {
            childNodes = (children[id] ?? []).compactMap {
                guard !nextAncestors.contains($0) else { return nil }
                return buildSubagent(
                    id: $0,
                    fragments: fragments,
                    children: children,
                    ancestors: nextAncestors
                )
            }
        } else {
            childNodes = []
        }

        var aggregate = directAggregate(for: fragment)
        if !inserted { aggregate.completeness = .partial }
        var hasActivity = fragment.hasActivityInSlice
        var startedAt = fragment.startedAt
        var lastActivityAt = fragment.lastActivityAt
        var repositoryPath = fragment.repositoryPath
        var preview = fragment.preview

        for child in childNodes {
            aggregate.merge(child.aggregate, keyPrefix: child.subagent.id)
            hasActivity = hasActivity || child.hasActivityInSlice
            startedAt = earlierDate(startedAt, child.startedAt)
            lastActivityAt = laterDate(lastActivityAt, child.lastActivityAt)
            repositoryPath = repositoryPath ?? child.repositoryPath
            preview = preview ?? child.preview
        }

        let lists = sessionToolLists(from: aggregate.toolCalls)
        let node = SessionSubagentUsage(
            id: fragment.id,
            name: fragment.name,
            kind: fragment.kind,
            status: fragment.status,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            ownUsage: fragment.ownUsage,
            inclusiveUsage: aggregate.usage,
            toolCallCount: aggregate.toolCalls.count + aggregate.reportedToolCallCount,
            mcpCallCount: aggregate.toolCalls.values.filter { $0.mcpServer != nil }.count,
            tools: lists.tools,
            mcps: lists.mcps,
            models: sessionModelList(from: aggregate.modelUsages),
            children: childNodes.map(\.subagent),
            dataCompleteness: aggregate.completeness
        )
        return BuiltNode(
            subagent: node,
            aggregate: aggregate,
            hasActivityInSlice: hasActivity,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            repositoryPath: repositoryPath,
            preview: preview
        )
    }

    private static func directAggregate(for fragment: ParsedSessionFragment) -> ParsedSessionAggregate {
        var calls: [String: ParsedSessionToolCall] = [:]
        for (id, call) in fragment.toolCalls {
            calls["\(fragment.id):\(id)"] = call
        }
        return ParsedSessionAggregate(
            usage: fragment.ownUsage,
            modelUsages: fragment.modelUsages,
            toolCalls: calls,
            reportedToolCallCount: fragment.reportedToolCallCount,
            completeness: fragment.dataCompleteness
        )
    }

    private static func earlierDate(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case let (left?, right?): return min(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private static func laterDate(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }
}

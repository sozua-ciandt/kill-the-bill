import XCTest
@testable import KillTheBill

final class SessionPresentationTests: XCTestCase {
    func testCostSortUsesInclusiveKnownValueAndPlacesUnavailableLast() {
        let now = Date(timeIntervalSince1970: 10_000)
        let unavailable = makeSession(
            id: "unavailable",
            usage: makeUsage(invocations: 3, unpriced: 3),
            lastActivityAt: now
        )
        let exact = makeSession(
            id: "exact",
            usage: makeUsage(cost: 4, invocations: 2),
            lastActivityAt: now.addingTimeInterval(-100)
        )
        let partial = makeSession(
            id: "partial",
            usage: makeUsage(cost: 7, invocations: 3, unpriced: 1),
            lastActivityAt: now.addingTimeInterval(-200)
        )

        let sorted = SessionPresentation.sortedSessions(
            [unavailable, exact, partial],
            showEvents: false
        )

        XCTAssertEqual(sorted.map(\.id.rawValue), ["partial", "exact", "unavailable"])
    }

    func testEventSortUsesModelInvocationsThenRecentActivity() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        let mostEvents = makeSession(
            id: "most",
            usage: makeUsage(cost: 1, invocations: 8),
            lastActivityAt: old
        )
        let recentTie = makeSession(
            id: "recent-tie",
            usage: makeUsage(cost: 100, invocations: 4),
            lastActivityAt: recent
        )
        let oldTie = makeSession(
            id: "old-tie",
            usage: makeUsage(cost: 200, invocations: 4),
            lastActivityAt: old
        )

        let sorted = SessionPresentation.sortedSessions(
            [oldTie, recentTie, mostEvents],
            showEvents: true
        )

        XCTAssertEqual(sorted.map(\.id.rawValue), ["most", "recent-tie", "old-tie"])
    }

    func testVisibleCostTotalDistinguishesUnavailablePartialAndExact() {
        let unavailable = makeSession(
            id: "unavailable",
            usage: makeUsage(invocations: 2, unpriced: 2)
        )
        XCTAssertEqual(
            SessionPresentation.visibleCostTotal(for: [unavailable]),
            .unavailable
        )

        let exact = makeSession(
            id: "exact",
            usage: makeUsage(cost: 3.5, invocations: 1)
        )
        XCTAssertEqual(
            SessionPresentation.visibleCostTotal(for: [exact, unavailable]),
            .lowerBound(3.5)
        )
        XCTAssertEqual(
            SessionPresentation.visibleCostTotal(for: [exact]),
            .exact(3.5)
        )
        XCTAssertEqual(
            SessionPresentation.visibleCostTotal(for: []),
            .exact(0)
        )
    }

    func testSubagentRowsUseStablePathsAndDirectToolCounts() {
        let child = makeSubagent(id: "child", toolCallCount: 2)
        let parent = makeSubagent(
            id: "parent",
            toolCallCount: 5,
            children: [child]
        )

        let first = SessionPresentation.subagentRows(from: [parent])
        let second = SessionPresentation.subagentRows(from: [parent])

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.depth), [0, 1])
        XCTAssertEqual(first.map(\.ownToolCallCount), [3, 2])
        XCTAssertEqual(first.map(\.agent.id), ["parent", "child"])
    }

    func testAllTimeQueryIsDifferentFromNeverRequested() {
        let neverRequested: SessionQuery? = nil
        let allTime: SessionQuery? = SessionQuery(interval: nil)

        XCTAssertNil(neverRequested)
        XCTAssertNotNil(allTime)
        XCTAssertNil(allTime?.interval)
    }

    func testNewSessionUIKeysExistInBothLanguages() {
        let keys = [
            "sessions.period.apply",
            "sessions.period.pending",
            "sessions.detail.events",
            "sessions.detail.reasoning_tokens",
            "sessions.detail.total_only_tokens",
            "sessions.detail.estimated_partial",
            "sessions.detail.estimate_unavailable",
            "sessions.accessibility.open_detail",
            "sessions.accessibility.subagent_level",
        ]

        for language in [AppLanguage.english, .portugueseBrazil] {
            let localizer = AppLocalizer(language: language)
            for key in keys {
                XCTAssertNotEqual(localizer.text(key), key, "Missing \(key) for \(language)")
            }
        }
    }

    private func makeUsage(
        cost: Double = 0,
        invocations: Int,
        unpriced: Int = 0
    ) -> SessionUsage {
        SessionUsage(
            tokens: SessionTokenUsage(),
            pricedCostUSD: cost,
            modelInvocationCount: invocations,
            unpricedModelInvocationCount: unpriced
        )
    }

    private func makeSession(
        id: String,
        usage: SessionUsage,
        lastActivityAt: Date? = nil
    ) -> UsageSession {
        UsageSession(
            id: UsageSessionID(harness: .codex, rawValue: id),
            title: id,
            preview: id,
            repositoryPath: nil,
            repositoryName: "repo",
            gitBranch: nil,
            startedAt: lastActivityAt,
            lastActivityAt: lastActivityAt,
            ownUsage: usage,
            inclusiveUsage: usage,
            humanTurnCount: 1,
            toolCallCount: 0,
            mcpCallCount: 0,
            tools: [],
            mcps: [],
            models: [],
            subagents: [],
            dataCompleteness: .complete
        )
    }

    private func makeSubagent(
        id: String,
        toolCallCount: Int,
        children: [SessionSubagentUsage] = []
    ) -> SessionSubagentUsage {
        return SessionSubagentUsage(
            id: id,
            name: nil,
            kind: nil,
            status: nil,
            startedAt: nil,
            lastActivityAt: nil,
            ownUsage: SessionUsage(),
            inclusiveUsage: SessionUsage(),
            toolCallCount: toolCallCount,
            mcpCallCount: 0,
            tools: [],
            mcps: [],
            models: [],
            children: children,
            dataCompleteness: .complete
        )
    }

    func testOverviewRankingSortsByMonthlyOrDailyPreference() {
        let ws1 = WorkspaceUsage(
            id: "proj-heavy-monthly",
            displayName: "proj-heavy-monthly",
            costUSD: 5.0,
            monthlyCostUSD: 100.0,
            inputTokens: 0,
            outputTokens: 0,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
            sessionCount: 1,
            turnCount: 10,
            unpricedTurnCount: 0
        )
        let ws2 = WorkspaceUsage(
            id: "proj-heavy-daily",
            displayName: "proj-heavy-daily",
            costUSD: 50.0,
            monthlyCostUSD: 60.0,
            inputTokens: 0,
            outputTokens: 0,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
            sessionCount: 1,
            turnCount: 20,
            unpricedTurnCount: 0
        )

        let sortedMonthly = OverviewPresentation.sortedWorkspaces([ws1, ws2], ranking: .monthly, showEvents: false)
        XCTAssertEqual(sortedMonthly.map(\.id), ["proj-heavy-monthly", "proj-heavy-daily"])

        let sortedDaily = OverviewPresentation.sortedWorkspaces([ws1, ws2], ranking: .daily, showEvents: false)
        XCTAssertEqual(sortedDaily.map(\.id), ["proj-heavy-daily", "proj-heavy-monthly"])

        let m1 = ModelUsage(id: "model-m", costUSD: 1.0, monthlyCostUSD: 50.0, turnCount: 5, unpricedTurnCount: 0)
        let m2 = ModelUsage(id: "model-d", costUSD: 10.0, monthlyCostUSD: 20.0, turnCount: 15, unpricedTurnCount: 0)

        let modelsMonthly = OverviewPresentation.sortedModels([m1, m2], ranking: .monthly, showEvents: false)
        XCTAssertEqual(modelsMonthly.map(\.id), ["model-m", "model-d"])

        let modelsDaily = OverviewPresentation.sortedModels([m1, m2], ranking: .daily, showEvents: false)
        XCTAssertEqual(modelsDaily.map(\.id), ["model-d", "model-m"])
    }
}

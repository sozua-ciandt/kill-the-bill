import Foundation
import XCTest
@testable import KillTheBill

final class UsageModelTests: XCTestCase {
    func testAccumulatorDeduplicatesSessionFilesAndTracksUnpricedTurns() throws {
        let temp = try TempDirectory()
        let file = try temp.file("session.jsonl", contents: "{}")

        var accumulator = UsageAccumulator()
        accumulator.registerSession(file, workspaceID: "app", displayName: "app")
        accumulator.registerSession(file, workspaceID: "app", displayName: "app")
        accumulator.addTurn(workspaceID: "app", displayName: "app", modelID: "known", input: 100, output: 20, cacheWrite: 0, cacheRead: 10, costUSD: 0.01)
        accumulator.addTurn(workspaceID: "app", displayName: "app", modelID: "unknown", input: 1, output: 2, cacheWrite: 0, cacheRead: 0, costUSD: nil)

        let usage = accumulator.dailyUsage()

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.turnCount, 2)
        XCTAssertEqual(usage.unpricedTurnCount, 1)
        XCTAssertEqual(usage.totalTokens, 133)
        assertDoubleEqual(usage.totalCostUSD, 0.01)
    }

    func testCombinedMergesWorkspaceAndModelTotals() {
        let left = DailyUsage(
            totalCostUSD: 1,
            inputTokens: 10,
            outputTokens: 20,
            cacheWriteTokens: 1,
            cacheReadTokens: 2,
            sessionCount: 1,
            turnCount: 1,
            monthlyTurnCount: 4,
            lastUpdated: Date(timeIntervalSince1970: 10),
            perWorkspace: [WorkspaceUsage(id: "app", displayName: "app", costUSD: 1, inputTokens: 10, outputTokens: 20, cacheWriteTokens: 1, cacheReadTokens: 2, sessionCount: 1, turnCount: 1, unpricedTurnCount: 0)],
            perModel: [ModelUsage(id: "model", costUSD: 1, turnCount: 1, unpricedTurnCount: 0)]
        )
        let right = DailyUsage(
            totalCostUSD: 2,
            inputTokens: 30,
            outputTokens: 40,
            cacheWriteTokens: 3,
            cacheReadTokens: 4,
            sessionCount: 2,
            turnCount: 3,
            unpricedTurnCount: 1,
            monthlyTurnCount: 5,
            lastUpdated: Date(timeIntervalSince1970: 20),
            perWorkspace: [WorkspaceUsage(id: "app", displayName: "app", costUSD: 2, inputTokens: 30, outputTokens: 40, cacheWriteTokens: 3, cacheReadTokens: 4, sessionCount: 2, turnCount: 3, unpricedTurnCount: 1)],
            perModel: [ModelUsage(id: "model", costUSD: 2, turnCount: 3, unpricedTurnCount: 1)]
        )

        let combined = DailyUsage.combined([left, right])

        XCTAssertEqual(combined.sessionCount, 3)
        XCTAssertEqual(combined.turnCount, 4)
        XCTAssertEqual(combined.monthlyTurnCount, 9)
        XCTAssertEqual(combined.lastUpdated, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(combined.perWorkspace.first?.sessionCount, 3)
        XCTAssertEqual(combined.perModel.first?.turnCount, 4)
        assertDoubleEqual(combined.totalCostUSD, 3)
    }

    func testTiedWorkspaceAndModelTotalsUseStableIDOrdering() {
        let usages = ["zeta", "alpha"].map { id in
            DailyUsage(
                perWorkspace: [WorkspaceUsage(
                    id: id,
                    displayName: id,
                    costUSD: 1,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheWriteTokens: 0,
                    cacheReadTokens: 0,
                    sessionCount: 1,
                    turnCount: 1,
                    unpricedTurnCount: 0
                )],
                perModel: [ModelUsage(
                    id: id,
                    costUSD: 1,
                    turnCount: 1,
                    unpricedTurnCount: 0
                )]
            )
        }

        let combined = DailyUsage.combined(usages)

        XCTAssertEqual(combined.perWorkspace.map(\.id), ["alpha", "zeta"])
        XCTAssertEqual(combined.perModel.map(\.id), ["alpha", "zeta"])
    }
}

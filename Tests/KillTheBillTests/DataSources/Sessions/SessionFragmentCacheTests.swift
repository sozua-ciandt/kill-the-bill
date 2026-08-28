import Foundation
import XCTest
@testable import KillTheBill

final class SessionFragmentCacheTests: XCTestCase {
    func testCacheStoresAndClearsFragments() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("session.jsonl")
        try "test-content".write(to: fileURL, atomically: true, encoding: .utf8)

        var parseCount = 0
        let base1 = SessionFragmentCache.shared.baseFragment(for: fileURL) {
            parseCount += 1
            return BaseSessionFragment(
                harness: .claudeCode,
                id: "sess-1",
                isSubagent: false,
                repositoryFallbackName: "TestRepo"
            )
        }

        XCTAssertNotNil(base1)
        XCTAssertEqual(parseCount, 1)

        // Second call should return cached without re-parsing
        let base2 = SessionFragmentCache.shared.baseFragment(for: fileURL) {
            parseCount += 1
            return nil
        }
        XCTAssertNotNil(base2)
        XCTAssertEqual(base2?.id, "sess-1")
        XCTAssertEqual(parseCount, 1)

        // Clear cache and verify re-parsing occurs
        SessionFragmentCache.shared.clear()
        let base3 = SessionFragmentCache.shared.baseFragment(for: fileURL) {
            parseCount += 1
            return BaseSessionFragment(
                harness: .claudeCode,
                id: "sess-2",
                isSubagent: false,
                repositoryFallbackName: "TestRepo"
            )
        }
        XCTAssertNotNil(base3)
        XCTAssertEqual(base3?.id, "sess-2")
        XCTAssertEqual(parseCount, 2)
    }

    func testBaseFragmentSlicingRespectsIntervalAndComputesPreciseCosts() {
        var base = BaseSessionFragment(
            harness: .claudeCode,
            id: "sess-123",
            isSubagent: false,
            repositoryFallbackName: "Repo"
        )

        let d1 = Date(timeIntervalSince1970: 1000)
        let d3 = Date(timeIntervalSince1970: 3000)

        base.invocations.append(BaseSessionEventInvocation(
            rawModel: "claude-sonnet-4-5",
            normalizedModel: "claude-sonnet-4-5",
            tokens: SessionTokenUsage(inputTokens: 1000, outputTokens: 500, cacheWriteTokens: 100, cacheReadTokens: 200),
            date: d1
        ))
        base.invocations.append(BaseSessionEventInvocation(
            rawModel: "claude-sonnet-4-5",
            normalizedModel: "claude-sonnet-4-5",
            tokens: SessionTokenUsage(inputTokens: 2000, outputTokens: 1000, cacheWriteTokens: 0, cacheReadTokens: 0),
            date: d3
        ))

        base.humanTurns.append(BaseSessionEventHumanTurn(id: "turn-1", date: d1))
        base.humanTurns.append(BaseSessionEventHumanTurn(id: "turn-2", date: d3))

        let pricing = ModelPricing(models: [
            "claude-sonnet-4-5": TokenPricing(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)
        ])

        // Slice with interval covering only d1
        let interval = DateInterval(start: Date(timeIntervalSince1970: 500), end: Date(timeIntervalSince1970: 1500))
        let sliced = base.slice(pricing: pricing, interval: interval)

        XCTAssertEqual(sliced.humanTurnCount, 1)
        XCTAssertEqual(sliced.ownUsage.modelInvocationCount, 1)
        XCTAssertEqual(sliced.ownUsage.tokens.inputTokens, 1000)
        XCTAssertEqual(sliced.ownUsage.tokens.outputTokens, 500)
        XCTAssertTrue(sliced.hasActivityInSlice)

        // Cost for d1: 1000*3/1M + 500*15/1M + 100*3.75/1M + 200*0.3/1M = 0.003 + 0.0075 + 0.000375 + 0.00006 = 0.010935
        assertDoubleEqual(sliced.ownUsage.pricedCostUSD, 0.010935)

        // Full slice (interval = nil)
        let full = base.slice(pricing: pricing, interval: nil)
        XCTAssertEqual(full.humanTurnCount, 2)
        XCTAssertEqual(full.ownUsage.modelInvocationCount, 2)
        XCTAssertEqual(full.ownUsage.tokens.inputTokens, 3000)
        XCTAssertEqual(full.ownUsage.tokens.outputTokens, 1500)
        XCTAssertTrue(full.hasActivityInSlice)
    }
}

import Foundation
import XCTest
@testable import KillTheBill

final class CodexLogParserTests: XCTestCase {
    func testParsesCodexTokenCountsWithCachedInput() throws {
        let temp = try TempDirectory()
        let session = """
        {"timestamp":"2026-06-07T01:00:00Z","type":"session_meta","payload":{"cwd":"\(temp.url.path)/my-app","source":"cli"}}
        {"timestamp":"2026-06-07T01:00:01Z","type":"turn_context","payload":{"cwd":"\(temp.url.path)/my-app","model":"gpt-5-5"}}
        {"timestamp":"2026-06-07T01:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":250000,"output_tokens":100000,"total_tokens":1100000}}}}
        """
        let file = try temp.file("sessions/rollout.jsonl", contents: session)

        let usage = CodexLogParser.parseSessions(files: [file], pricing: testPricing())

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.turnCount, 1)
        XCTAssertEqual(usage.inputTokens, 750_000)
        XCTAssertEqual(usage.cacheReadTokens, 250_000)
        XCTAssertEqual(usage.outputTokens, 100_000)
        XCTAssertEqual(usage.perWorkspace.first?.displayName, "my-app")
        XCTAssertEqual(usage.perModel.first?.id, "gpt-5.5")
        assertDoubleEqual(usage.totalCostUSD, 6.875)
    }

    func testTotalOnlyUsageCountsAsUnpricedTurn() throws {
        let temp = try TempDirectory()
        let session = """
        {"type":"session_meta","payload":{"cwd":"\(temp.url.path)/my-app"}}
        {"type":"turn_context","payload":{"model":"gpt-5-5"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"total_tokens":8019}}}}
        """
        let file = try temp.file("sessions/rollout.jsonl", contents: session)

        let usage = CodexLogParser.parseSessions(files: [file], pricing: testPricing())

        XCTAssertEqual(usage.turnCount, 1)
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertEqual(usage.unpricedTurnCount, 1)
        XCTAssertTrue(usage.hasUnpricedUsage)
    }

    func testCountMonthlyTurnsIncludesTotalOnlyUsage() throws {
        let temp = try TempDirectory()
        let session = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"total_tokens":8019}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":3,"total_tokens":13}}}}
        """
        let file = try temp.file("sessions/rollout.jsonl", contents: session)

        XCTAssertEqual(CodexLogParser.countMonthlyTurns(files: [file]), 2)
    }
}

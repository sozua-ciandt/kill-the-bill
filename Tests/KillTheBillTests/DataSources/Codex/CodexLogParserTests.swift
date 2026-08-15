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

    func testRootAndSubagentAreOneLogicalSessionWithoutDuplicatingInheritedCost() throws {
        let temp = try TempDirectory()
        let cwd = temp.url.appendingPathComponent("my-app").path
        let root = try temp.file(
            "sessions/root.jsonl",
            contents: """
            {"timestamp":"2026-08-14T12:00:00Z","type":"session_meta","ordinal":0,"payload":{"id":"root-id","session_id":"root-id","thread_source":"user","cwd":"\(cwd)"}}
            {"timestamp":"2026-08-14T12:00:01Z","type":"turn_context","ordinal":1,"payload":{"model":"gpt-5-5","cwd":"\(cwd)"}}
            {"timestamp":"2026-08-14T12:00:02Z","type":"event_msg","ordinal":2,"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1000000}}}}
            """
        )
        let child = try temp.file(
            "sessions/child.jsonl",
            contents: """
            {"timestamp":"2026-08-14T12:01:00Z","type":"session_meta","ordinal":0,"payload":{"id":"child-id","session_id":"child-id","thread_source":"subagent","parent_thread_id":"root-id","subagent_history_start_ordinal":10,"cwd":"\(cwd)"}}
            {"timestamp":"2026-08-14T12:00:02Z","type":"event_msg","ordinal":2,"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1000000}}}}
            {"timestamp":"2026-08-14T12:01:01Z","type":"turn_context","ordinal":10,"payload":{"model":"gpt-5-5","cwd":"\(cwd)"}}
            {"timestamp":"2026-08-14T12:01:02Z","type":"event_msg","ordinal":11,"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":500000}}}}
            """
        )

        let usage = CodexLogParser.parseSessions(
            files: [child, root],
            pricing: testPricing()
        )

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.perWorkspace.first?.sessionCount, 1)
        XCTAssertEqual(usage.turnCount, 2)
        XCTAssertEqual(usage.inputTokens, 1_500_000)
        assertDoubleEqual(usage.totalCostUSD, 7.5)
    }

    func testSessionWithoutUsageInDateFilterIsNotRegistered() throws {
        let temp = try TempDirectory()
        let session = """
        {"timestamp":"2026-08-13T12:00:00Z","type":"session_meta","payload":{"id":"outside-id","thread_source":"user","cwd":"\(temp.url.path)/my-app"}}
        {"timestamp":"2026-08-13T12:00:01Z","type":"turn_context","payload":{"model":"gpt-5-5"}}
        {"timestamp":"2026-08-13T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1000000}}}}
        """
        let file = try temp.file("sessions/outside-period.jsonl", contents: session)

        let usage = CodexLogParser.parseSessions(
            files: [file],
            pricing: testPricing(),
            dateFilter: DateComponents(year: 2026, month: 8, day: 14)
        )

        XCTAssertEqual(usage.sessionCount, 0)
        XCTAssertEqual(usage.turnCount, 0)
        XCTAssertTrue(usage.perWorkspace.isEmpty)
        assertDoubleEqual(usage.totalCostUSD, 0)
    }
}

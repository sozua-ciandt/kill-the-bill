import Foundation
import XCTest
@testable import KillTheBill

/// Summary and detail parsers are separate projections by design. These tests
/// protect the token and pricing fields that both projections must interpret in
/// the same way.
final class ParserProjectionContractTests: XCTestCase {
    func testClaudeSummaryAndDetailProjectionsAgreeOnUsage() throws {
        let temp = try TempDirectory()
        let project = temp.url.appendingPathComponent("-Users-test-Projects-contract-app")
        let file = try temp.file(
            "-Users-test-Projects-contract-app/claude-session.jsonl",
            contents: """
            {"type":"user","uuid":"user-1","timestamp":"2026-08-14T10:00:00Z","cwd":"/tmp/contract-app","message":{"role":"user","content":"Check usage"}}
            {"type":"assistant","uuid":"assistant-1","timestamp":"2026-08-14T10:01:00Z","cwd":"/tmp/contract-app","message":{"id":"message-1","role":"assistant","model":"claude-sonnet-4-5","usage":{"input_tokens":700000,"output_tokens":100000,"cache_creation_input_tokens":100000,"cache_read_input_tokens":200000},"content":[]}}
            """
        )
        let pricing = testPricing()

        let summary = ClaudeLogParser.parseTranscripts(
            dirs: [project],
            files: [file],
            pricing: pricing
        )
        let detail = try XCTUnwrap(SessionLogParser.parse(
            claudeTranscriptDirs: [project],
            claudeFiles: [file],
            codexFiles: [],
            pricing: pricing
        ).first)

        assertSharedUsage(summary: summary, detail: detail)
    }

    func testCodexSummaryAndDetailProjectionsAgreeOnUsage() throws {
        let temp = try TempDirectory()
        let file = try temp.file(
            "sessions/codex-session.jsonl",
            contents: """
            {"timestamp":"2026-08-14T10:00:00Z","type":"session_meta","payload":{"id":"codex-session","thread_source":"user","cwd":"/tmp/contract-app"}}
            {"timestamp":"2026-08-14T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Check usage"}}
            {"timestamp":"2026-08-14T10:00:02Z","type":"turn_context","payload":{"model":"gpt-5-5","cwd":"/tmp/contract-app"}}
            {"timestamp":"2026-08-14T10:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":200000,"cache_write_input_tokens":100000,"output_tokens":100000,"total_tokens":1100000}}}}
            """
        )
        let pricing = testPricing([
            "gpt-5.5": TokenPricing(
                input: 5,
                output: 30,
                cacheWrite: 2,
                cacheRead: 0.5
            )
        ])

        let summary = CodexLogParser.parseSessions(files: [file], pricing: pricing)
        let detail = try XCTUnwrap(SessionLogParser.parse(
            claudeTranscriptDirs: [],
            claudeFiles: [],
            codexFiles: [file],
            pricing: pricing
        ).first)

        assertSharedUsage(summary: summary, detail: detail)
        XCTAssertEqual(summary.cacheWriteTokens, 100_000)
    }

    private func assertSharedUsage(
        summary: DailyUsage,
        detail: UsageSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(summary.inputTokens, detail.inclusiveUsage.tokens.inputTokens, file: file, line: line)
        XCTAssertEqual(summary.outputTokens, detail.inclusiveUsage.tokens.outputTokens, file: file, line: line)
        XCTAssertEqual(summary.cacheWriteTokens, detail.inclusiveUsage.tokens.cacheWriteTokens, file: file, line: line)
        XCTAssertEqual(summary.cacheReadTokens, detail.inclusiveUsage.tokens.cacheReadTokens, file: file, line: line)
        XCTAssertEqual(summary.turnCount, detail.modelInvocationCount, file: file, line: line)
        XCTAssertEqual(summary.unpricedTurnCount, detail.inclusiveUsage.unpricedModelInvocationCount, file: file, line: line)
        XCTAssertEqual(
            summary.totalCostUSD,
            detail.inclusiveUsage.pricedCostUSD,
            accuracy: 0.000001,
            file: file,
            line: line
        )
    }
}

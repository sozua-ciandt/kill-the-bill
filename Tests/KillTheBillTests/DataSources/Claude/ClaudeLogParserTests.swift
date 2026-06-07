import Foundation
import XCTest
@testable import KillTheBill

final class ClaudeLogParserTests: XCTestCase {
    func testParsesClaudeTranscriptAndDeduplicatesRepeatedUsage() throws {
        let temp = try TempDirectory()
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_creation_input_tokens":10000,"cache_read_input_tokens":20000}}}
        {"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_creation_input_tokens":10000,"cache_read_input_tokens":20000}}}
        {"type":"user","message":{"role":"user"}}
        """
        let file = try temp.file("-Users-diogor-Projetos-my-app/session.jsonl", contents: transcript)

        let usage = ClaudeLogParser.parseTranscripts(
            dirs: [file.deletingLastPathComponent()],
            files: [file],
            pricing: testPricing()
        )

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.turnCount, 1)
        XCTAssertEqual(usage.inputTokens, 1_000_000)
        XCTAssertEqual(usage.outputTokens, 100_000)
        XCTAssertEqual(usage.cacheWriteTokens, 10_000)
        XCTAssertEqual(usage.cacheReadTokens, 20_000)
        XCTAssertEqual(usage.perWorkspace.first?.displayName, "my-app")
        XCTAssertEqual(usage.perModel.first?.id, "claude-sonnet-4-5")
        assertDoubleEqual(usage.totalCostUSD, 4.5435)
    }

    func testCountMonthlyTurnsDeduplicatesWithinSession() throws {
        let temp = try TempDirectory()
        let transcript = """
        {"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","message":{"usage":{"input_tokens":2,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let file = try temp.file("project/session.jsonl", contents: transcript)

        XCTAssertEqual(ClaudeLogParser.countMonthlyTurns(files: [file]), 2)
    }
}

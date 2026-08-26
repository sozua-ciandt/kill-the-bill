import Foundation
import SQLite3
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

    func testOpenCodeSummaryAndDetailProjectionsAgreeOnUsage() throws {
        let temp = try TempDirectory()
        let dbPath = temp.url.appendingPathComponent("opencode.db").path
        let dbURL = URL(fileURLWithPath: dbPath)

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            XCTFail("Failed to open test db")
            return
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, vcs TEXT, name TEXT, icon_url TEXT, icon_url_override TEXT, icon_color TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_initialized INTEGER, sandboxes TEXT NOT NULL, commands TEXT);
        CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT, parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, path TEXT, title TEXT NOT NULL, version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER, summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT, metadata TEXT, cost REAL DEFAULT 0 NOT NULL, tokens_input INTEGER DEFAULT 0 NOT NULL, tokens_output INTEGER DEFAULT 0 NOT NULL, tokens_reasoning INTEGER DEFAULT 0 NOT NULL, tokens_cache_read INTEGER DEFAULT 0 NOT NULL, tokens_cache_write INTEGER DEFAULT 0 NOT NULL, revert TEXT, permission TEXT, agent TEXT, model TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_compacting INTEGER, time_archived INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
        """
        sqlite3_exec(db, schema, nil, nil, nil)

        let ts: Int64 = 1786622400000
        sqlite3_exec(db, "INSERT INTO project (id, worktree, sandboxes, time_created, time_updated) VALUES ('p1', '/tmp/contract-app', '[]', \(ts), \(ts));", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO session (id, project_id, slug, directory, title, version, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, agent, model, time_created, time_updated) VALUES ('s1', 'p1', 'slug', '/tmp/contract-app', 'Contract test', '1.0', 0, 0, 0, 0, 0, 0, 'build', '{\"id\":\"claude-sonnet-4-5\",\"providerID\":\"flow\"}', \(ts), \(ts));", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m-u1', 's1', \(ts), \(ts), '{\"role\":\"user\",\"time\":{\"created\":\(ts)}}');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('p-t1', 'm-u1', 's1', \(ts), \(ts), '{\"type\":\"text\",\"text\":\"Check usage\"}');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('m-a1', 's1', \(ts+100), \(ts+100), '{\"parentID\":\"m-u1\",\"role\":\"assistant\",\"mode\":\"build\",\"tokens\":{\"input\":700000,\"output\":100000,\"reasoning\":0,\"cache\":{\"read\":200000,\"write\":100000}},\"modelID\":\"claude-sonnet-4-5\",\"providerID\":\"flow\",\"time\":{\"created\":\(ts+100)}}');", nil, nil, nil)

        let pricing = testPricing()
        let summary = OpenCodeDBMonitor.parseUsage(dbURL: dbURL, pricing: pricing, dateFilter: nil)
        let detail = try XCTUnwrap(SessionLogParser.parse(
            claudeTranscriptDirs: [],
            claudeFiles: [],
            codexFiles: [],
            opencodeDB: dbURL,
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

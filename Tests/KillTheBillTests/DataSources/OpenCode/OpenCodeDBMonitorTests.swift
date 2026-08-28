import Foundation
import SQLite3
import XCTest
@testable import KillTheBill

final class OpenCodeDBMonitorTests: XCTestCase {

    private func createTestDB(at path: String) throws -> URL {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            XCTFail("Failed to open test database at \(path)")
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE project (
            id TEXT PRIMARY KEY,
            worktree TEXT NOT NULL,
            vcs TEXT,
            name TEXT,
            icon_url TEXT,
            icon_url_override TEXT,
            icon_color TEXT,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            time_initialized INTEGER,
            sandboxes TEXT NOT NULL,
            commands TEXT
        );

        CREATE TABLE session (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            workspace_id TEXT,
            parent_id TEXT,
            slug TEXT NOT NULL,
            directory TEXT NOT NULL,
            path TEXT,
            title TEXT NOT NULL,
            version TEXT NOT NULL,
            share_url TEXT,
            summary_additions INTEGER,
            summary_deletions INTEGER,
            summary_files INTEGER,
            summary_diffs TEXT,
            metadata TEXT,
            cost REAL DEFAULT 0 NOT NULL,
            tokens_input INTEGER DEFAULT 0 NOT NULL,
            tokens_output INTEGER DEFAULT 0 NOT NULL,
            tokens_reasoning INTEGER DEFAULT 0 NOT NULL,
            tokens_cache_read INTEGER DEFAULT 0 NOT NULL,
            tokens_cache_write INTEGER DEFAULT 0 NOT NULL,
            revert TEXT,
            permission TEXT,
            agent TEXT,
            model TEXT,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            time_compacting INTEGER,
            time_archived INTEGER
        );

        CREATE TABLE message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );

        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        """

        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            XCTFail("Failed to create schema: \(String(cString: sqlite3_errmsg(db)))")
            throw NSError(domain: "SQLite", code: 2)
        }

        return URL(fileURLWithPath: path)
    }

    func testParsesOpenCodeDailyUsageAndTokenCounts() throws {
        let temp = try TempDirectory()
        let dbPath = temp.url.appendingPathComponent("opencode.db").path
        let dbURL = try createTestDB(at: dbPath)

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let projectID = "proj-uuid-1234"
        let sessionID = "ses-root-001"
        let timestampMs: Int64 = 1786622400000 // 2026-08-14 12:00:00 UTC

        // Insert project with worktree /Users/diogor/Projetos/my-app
        let insertProj = "INSERT INTO project (id, worktree, sandboxes, time_created, time_updated) VALUES ('\(projectID)', '/Users/diogor/Projetos/my-app', '[]', \(timestampMs), \(timestampMs));"
        sqlite3_exec(db, insertProj, nil, nil, nil)

        // Insert root session
        let insertSession = """
        INSERT INTO session (
            id, project_id, slug, directory, title, version, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            agent, model, time_created, time_updated
        ) VALUES (
            '\(sessionID)', '\(projectID)', 'slug', '/Users/diogor/Projetos/my-app', 'Fix login issue', '1.0', 0.0,
            1000000, 100000, 0, 250000, 50000,
            'build', '{"id":"gpt-5.5","providerID":"flow-openai"}', \(timestampMs), \(timestampMs)
        );
        """
        sqlite3_exec(db, insertSession, nil, nil, nil)

        // Insert user message
        let userMsgData = """
        {"role":"user","time":{"created":\(timestampMs)},"agent":"build","model":{"providerID":"flow-openai","modelID":"gpt-5.5"}}
        """
        let insertUserMsg = "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-user-1', '\(sessionID)', \(timestampMs), \(timestampMs), '\(userMsgData)');"
        sqlite3_exec(db, insertUserMsg, nil, nil, nil)

        // Insert assistant message with tokens
        let assistantMsgData = """
        {"parentID":"msg-user-1","role":"assistant","mode":"build","agent":"build","cost":0,"tokens":{"input":1000000,"output":100000,"reasoning":0,"cache":{"read":250000,"write":50000}},"modelID":"gpt-5.5","providerID":"flow-openai","time":{"created":\(timestampMs)}}
        """
        let insertAssistantMsg = "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-asst-1', '\(sessionID)', \(timestampMs), \(timestampMs), '\(assistantMsgData)');"
        sqlite3_exec(db, insertAssistantMsg, nil, nil, nil)

        let usage = OpenCodeDBMonitor.parseUsage(
            dbURL: dbURL,
            pricing: testPricing(),
            dateFilter: nil
        )

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.turnCount, 1)
        XCTAssertEqual(usage.inputTokens, 1_000_000)
        XCTAssertEqual(usage.outputTokens, 100_000)
        XCTAssertEqual(usage.cacheReadTokens, 250_000)
        XCTAssertEqual(usage.cacheWriteTokens, 50_000)
        XCTAssertEqual(usage.totalTokens, 1_400_000)

        // Project name must NOT be UUID
        XCTAssertEqual(usage.perWorkspace.first?.displayName, "my-app")
        XCTAssertEqual(usage.perWorkspace.first?.sessionCount, 1)
        XCTAssertEqual(usage.perWorkspace.first?.turnCount, 1)

        // Model cost
        XCTAssertEqual(usage.perModel.first?.id, "gpt-5.5")
        // gpt-5.5 pricing: input 5, output 30, cacheRead 0.50 => 1M*5 + 0.1M*30 + 0.25M*0.50 = 5 + 3 + 0.125 = 8.125
        assertDoubleEqual(usage.totalCostUSD, 8.125)
    }

    func testParsesOpenCodeSessionsWithTurnsToolsAndSubagents() throws {
        let temp = try TempDirectory()
        let dbPath = temp.url.appendingPathComponent("opencode.db").path
        let dbURL = try createTestDB(at: dbPath)

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let projectID = "proj-uuid-5678"
        let rootSessionID = "ses-root-002"
        let childSessionID = "ses-child-002"
        let timestampMs: Int64 = 1786622400000 // 2026-08-14 12:00:00 UTC

        // Insert project
        let insertProj = "INSERT INTO project (id, worktree, sandboxes, time_created, time_updated) VALUES ('\(projectID)', '/Users/diogor/Projetos/billing-service', '[]', \(timestampMs), \(timestampMs));"
        sqlite3_exec(db, insertProj, nil, nil, nil)

        // Insert root session
        let insertRootSession = """
        INSERT INTO session (
            id, project_id, slug, directory, title, version, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            agent, model, time_created, time_updated
        ) VALUES (
            '\(rootSessionID)', '\(projectID)', 'slug', '/Users/diogor/Projetos/billing-service', 'Implement invoicing', '1.0', 0.0,
            0, 0, 0, 0, 0,
            'build', '{"id":"claude-sonnet-4-5","providerID":"flow"}', \(timestampMs), \(timestampMs)
        );
        """
        sqlite3_exec(db, insertRootSession, nil, nil, nil)

        // Insert child subagent session
        let insertChildSession = """
        INSERT INTO session (
            id, project_id, parent_id, slug, directory, title, version, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            agent, model, time_created, time_updated
        ) VALUES (
            '\(childSessionID)', '\(projectID)', '\(rootSessionID)', 'child-slug', '/Users/diogor/Projetos/billing-service', 'Code review (@explore subagent)', '1.0', 0.0,
            0, 0, 0, 0, 0,
            'explore', '{"id":"claude-sonnet-4-5","providerID":"flow"}', \(timestampMs + 1000), \(timestampMs + 1000)
        );
        """
        sqlite3_exec(db, insertChildSession, nil, nil, nil)

        // Root user message 1
        let userMsg1 = """
        {"role":"user","time":{"created":\(timestampMs)},"agent":"build"}
        """
        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-u1', '\(rootSessionID)', \(timestampMs), \(timestampMs), '\(userMsg1)');", nil, nil, nil)

        // Root prompt part
        let promptPart1 = """
        {"type":"text","text":"Implement the new invoice generator"}
        """
        sqlite3_exec(db, "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt-p1', 'msg-u1', '\(rootSessionID)', \(timestampMs), \(timestampMs), '\(promptPart1)');", nil, nil, nil)

        // Root assistant message 1
        let asstMsg1 = """
        {"parentID":"msg-u1","role":"assistant","mode":"build","agent":"build","tokens":{"input":1000000,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"claude-sonnet-4-5","providerID":"flow","time":{"created":\(timestampMs + 100)}}
        """
        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-a1', '\(rootSessionID)', \(timestampMs + 100), \(timestampMs + 100), '\(asstMsg1)');", nil, nil, nil)

        // Tool call part in root
        let toolPart = """
        {"type":"tool","tool":"bash","callID":"call-bash-1","state":{"status":"completed","output":"ok"}}
        """
        sqlite3_exec(db, "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt-t1', 'msg-a1', '\(rootSessionID)', \(timestampMs + 150), \(timestampMs + 150), '\(toolPart)');", nil, nil, nil)

        // Root user message 2 (second turn!)
        let userMsg2 = """
        {"role":"user","time":{"created":\(timestampMs + 200)},"agent":"build"}
        """
        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-u2', '\(rootSessionID)', \(timestampMs + 200), \(timestampMs + 200), '\(userMsg2)');", nil, nil, nil)

        // Child subagent assistant message
        let childAsstMsg = """
        {"parentID":"msg-u1","role":"assistant","mode":"explore","agent":"explore","tokens":{"input":500000,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"claude-sonnet-4-5","providerID":"flow","time":{"created":\(timestampMs + 1000)}}
        """
        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-child-a1', '\(childSessionID)', \(timestampMs + 1000), \(timestampMs + 1000), '\(childAsstMsg)');", nil, nil, nil)

        let sessions = SessionLogParser.parse(
            claudeTranscriptDirs: [],
            claudeFiles: [],
            codexFiles: [],
            opencodeDB: dbURL,
            pricing: testPricing()
        )

        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)

        XCTAssertEqual(session.id, UsageSessionID(harness: .opencode, rawValue: rootSessionID))
        XCTAssertEqual(session.title, "Implement invoicing")
        XCTAssertEqual(session.preview, "Implement the new invoice generator")
        XCTAssertEqual(session.repositoryName, "billing-service")
        XCTAssertEqual(session.humanTurnCount, 2) // 2 user turns, NOT 0!
        XCTAssertEqual(session.toolCallCount, 1)
        XCTAssertEqual(session.tools.first?.name, "bash")
        XCTAssertEqual(session.tools.first?.callCount, 1)

        // Subagents properly nested
        XCTAssertEqual(session.subagents.count, 1)
        XCTAssertEqual(session.subagents.first?.id, childSessionID)

        // Invocations and cost
        XCTAssertEqual(session.ownUsage.modelInvocationCount, 1)
        XCTAssertEqual(session.modelInvocationCount, 2) // root (1) + child (1)
        // claude-sonnet-4-5 input: 3 USD/M tokens. Root: 1M * 3 = 3. Child: 0.5M * 3 = 1.5. Inclusive = 4.5.
        assertDoubleEqual(session.ownUsage.pricedCostUSD, 3.0)
        assertDoubleEqual(session.inclusiveUsage.pricedCostUSD, 4.5)
    }

    func testDateFilterExcludesOutsideUsage() throws {
        let temp = try TempDirectory()
        let dbPath = temp.url.appendingPathComponent("opencode.db").path
        let dbURL = try createTestDB(at: dbPath)

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let projectID = "proj-uuid-outside"
        let sessionID = "ses-outside-001"
        let timestampOutsideMs: Int64 = 1786536000000 // 2026-08-13 12:00:00 UTC

        let insertProj = "INSERT INTO project (id, worktree, sandboxes, time_created, time_updated) VALUES ('\(projectID)', '/Users/diogor/Projetos/old-project', '[]', \(timestampOutsideMs), \(timestampOutsideMs));"
        sqlite3_exec(db, insertProj, nil, nil, nil)

        let insertSession = """
        INSERT INTO session (
            id, project_id, slug, directory, title, version, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            agent, model, time_created, time_updated
        ) VALUES (
            '\(sessionID)', '\(projectID)', 'slug', '/Users/diogor/Projetos/old-project', 'Old task', '1.0', 0.0,
            1000000, 0, 0, 0, 0,
            'build', '{"id":"gpt-5.5"}', \(timestampOutsideMs), \(timestampOutsideMs)
        );
        """
        sqlite3_exec(db, insertSession, nil, nil, nil)

        let msgData = """
        {"role":"assistant","tokens":{"input":1000000,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"gpt-5.5","time":{"created":\(timestampOutsideMs)}}
        """
        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-old-1', '\(sessionID)', \(timestampOutsideMs), \(timestampOutsideMs), '\(msgData)');", nil, nil, nil)

        let usage = OpenCodeDBMonitor.parseUsage(
            dbURL: dbURL,
            pricing: testPricing(),
            dateFilter: DateComponents(year: 2026, month: 8, day: 14) // Filter for Aug 14
        )

        XCTAssertEqual(usage.sessionCount, 0)
        XCTAssertEqual(usage.turnCount, 0)
        XCTAssertTrue(usage.perWorkspace.isEmpty)
        assertDoubleEqual(usage.totalCostUSD, 0)
    }

    func testParseUsageOverviewAggregatesTodayAndMonthSinglePass() throws {
        let temp = try TempDirectory()
        let dbPath = temp.url.appendingPathComponent("opencode.db").path
        let dbURL = try createTestDB(at: dbPath)

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let projectID = "proj-uuid-1"
        let sessionID = "ses-1"
        let timestampTodayMs: Int64 = 1786708800000 // 2026-08-14 12:00:00 UTC
        let timestampPastDayInMonthMs: Int64 = 1785672000000 // 2026-08-02 12:00:00 UTC

        sqlite3_exec(db, "INSERT INTO project (id, worktree, sandboxes, time_created, time_updated) VALUES ('\(projectID)', '/Users/diogor/Projetos/my-app', '[]', \(timestampTodayMs), \(timestampTodayMs));", nil, nil, nil)

        // Session 1 (Today)
        sqlite3_exec(db, """
        INSERT INTO session (
            id, project_id, slug, directory, title, version, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            agent, model, time_created, time_updated
        ) VALUES (
            '\(sessionID)', '\(projectID)', 'slug', '/Users/diogor/Projetos/my-app', 'Fix login issue', '1.0', 0.0,
            1000000, 100000, 0, 0, 0,
            'build', '{"id":"gpt-5.5"}', \(timestampTodayMs), \(timestampTodayMs)
        );
        """, nil, nil, nil)

        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-u1', '\(sessionID)', \(timestampTodayMs), \(timestampTodayMs), '{\"role\":\"user\"}');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-a1', '\(sessionID)', \(timestampTodayMs), \(timestampTodayMs), '{\"role\":\"assistant\",\"tokens\":{\"input\":1000000,\"output\":100000,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}},\"modelID\":\"gpt-5.5\"}');", nil, nil, nil)

        // Session 2 (Earlier this month)
        let sessionID2 = "ses-2"
        sqlite3_exec(db, """
        INSERT INTO session (
            id, project_id, slug, directory, title, version, cost,
            tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
            agent, model, time_created, time_updated
        ) VALUES (
            '\(sessionID2)', '\(projectID)', 'slug', '/Users/diogor/Projetos/my-app', 'Past task', '1.0', 0.0,
            2000000, 200000, 0, 0, 0,
            'build', '{"id":"gpt-5.5"}', \(timestampPastDayInMonthMs), \(timestampPastDayInMonthMs)
        );
        """, nil, nil, nil)

        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-u2', '\(sessionID2)', \(timestampPastDayInMonthMs), \(timestampPastDayInMonthMs), '{\"role\":\"user\"}');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg-a2', '\(sessionID2)', \(timestampPastDayInMonthMs), \(timestampPastDayInMonthMs), '{\"role\":\"assistant\",\"tokens\":{\"input\":2000000,\"output\":200000,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}},\"modelID\":\"gpt-5.5\"}');", nil, nil, nil)

        let todayComp = DateComponents(year: 2026, month: 8, day: 14)
        let monthComp = DateComponents(year: 2026, month: 8)

        let (todayUsage, monthUsage) = OpenCodeDBMonitor.parseUsageOverview(
            dbURL: dbURL,
            pricing: testPricing(),
            todayFilter: todayComp,
            monthFilter: monthComp
        )

        // Today usage only has session 1
        XCTAssertEqual(todayUsage.sessionCount, 1)
        XCTAssertEqual(todayUsage.turnCount, 1)
        XCTAssertEqual(todayUsage.inputTokens, 1_000_000)
        XCTAssertEqual(todayUsage.outputTokens, 100_000)

        // Month usage has both session 1 and session 2
        XCTAssertEqual(monthUsage.sessionCount, 2)
        XCTAssertEqual(monthUsage.turnCount, 2)
        XCTAssertEqual(monthUsage.inputTokens, 3_000_000)
        XCTAssertEqual(monthUsage.outputTokens, 300_000)
    }
}

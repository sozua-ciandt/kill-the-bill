import Foundation
import XCTest
@testable import KillTheBill

final class SessionLogParserTests: XCTestCase {
    func testClaudeGroupsSubagentWithoutDuplicatingAgentSummary() throws {
        let temp = try TempDirectory()
        let projectDirectory = temp.url.appendingPathComponent("-Users-diogor-Projetos-my-app")
        let cwd = temp.url.appendingPathComponent("my-app").path
        let root = try temp.file(
            "-Users-diogor-Projetos-my-app/root-session.jsonl",
            contents: """
            {"type":"ai-title","sessionId":"root-session","aiTitle":"Fix billing totals"}
            {"type":"user","uuid":"user-1","promptId":"prompt-1","timestamp":"2026-08-14T10:00:00Z","cwd":"\(cwd)","message":{"role":"user","content":"<environment_context>private metadata</environment_context> Build the billing screen"}}
            {"type":"assistant","uuid":"assistant-1","timestamp":"2026-08-14T10:01:00Z","cwd":"\(cwd)","message":{"id":"message-1","role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"agent-call","name":"Agent","input":{}},{"type":"tool_use","id":"mcp-call","name":"mcp__notion__search","input":{}}]}}
            {"type":"assistant","uuid":"assistant-1-repeat","timestamp":"2026-08-14T10:01:00Z","cwd":"\(cwd)","message":{"id":"message-1","role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"agent-call","name":"Agent","input":{}},{"type":"tool_use","id":"mcp-call","name":"mcp__notion__search","input":{}}]}}
            {"type":"user","uuid":"result-1","timestamp":"2026-08-14T10:02:00Z","cwd":"\(cwd)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"agent-call","content":"done"},{"type":"tool_result","tool_use_id":"mcp-call","content":"12345678"}]},"toolUseResult":{"agentId":"child-1","agentType":"worker","resolvedModel":"claude-sonnet-4-5-20250929","status":"completed","totalTokens":500000,"totalToolUseCount":1,"usage":{"input_tokens":500000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"iterations":1}}}
            {"type":"assistant","uuid":"assistant-2","timestamp":"2026-08-14T10:03:00Z","cwd":"\(cwd)","message":{"id":"message-2","role":"assistant","model":"unknown-model","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[]}}
            """
        )
        let child = try temp.file(
            "-Users-diogor-Projetos-my-app/root-session/subagents/agent-child-1.jsonl",
            contents: """
            {"type":"user","uuid":"child-user","timestamp":"2026-08-14T10:01:10Z","sessionId":"root-session","agentId":"child-1","cwd":"\(cwd)","message":{"role":"user","content":"Investigate totals"}}
            {"type":"assistant","uuid":"child-assistant","timestamp":"2026-08-14T10:01:20Z","sessionId":"root-session","agentId":"child-1","cwd":"\(cwd)","message":{"id":"child-message","role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":500000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"bash-call","name":"Bash","input":{}}]}}
            {"type":"user","uuid":"child-result","timestamp":"2026-08-14T10:01:30Z","sessionId":"root-session","agentId":"child-1","cwd":"\(cwd)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"bash-call","content":"abcdefgh"}]}}
            """
        )

        let sessions = SessionLogParser.parse(
            claudeTranscriptDirs: [projectDirectory],
            claudeFiles: [root, child],
            codexFiles: [],
            pricing: testPricing(),
            interval: nil
        )

        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(session.id, UsageSessionID(harness: .claudeCode, rawValue: "root-session"))
        XCTAssertEqual(session.title, "Fix billing totals")
        XCTAssertEqual(session.preview, "Build the billing screen")
        XCTAssertEqual(session.repositoryName, "my-app")
        XCTAssertEqual(session.humanTurnCount, 1)
        XCTAssertEqual(session.ownUsage.modelInvocationCount, 2)
        XCTAssertEqual(session.modelInvocationCount, 3)
        XCTAssertEqual(session.inclusiveUsage.unpricedModelInvocationCount, 1)
        assertDoubleEqual(session.inclusiveUsage.pricedCostUSD, 4.5)
        XCTAssertTrue(session.inclusiveUsage.isCostPartial)
        XCTAssertEqual(session.toolCallCount, 3)
        XCTAssertEqual(session.mcpCallCount, 1)
        XCTAssertEqual(session.mcps.first?.server, "notion")
        XCTAssertEqual(session.mcps.first?.tool, "search")
        XCTAssertEqual(session.mcps.first?.resultTokens.value, 2)
        XCTAssertEqual(session.mcps.first?.resultTokens.quality, .estimated)

        let subagent = try XCTUnwrap(session.subagents.first)
        XCTAssertEqual(session.subagents.count, 1)
        XCTAssertEqual(subagent.id, "child-1")
        XCTAssertEqual(subagent.dataCompleteness, .complete)
        XCTAssertEqual(subagent.toolCallCount, 1)
        assertDoubleEqual(subagent.ownUsage.pricedCostUSD, 1.5)
        assertDoubleEqual(subagent.inclusiveUsage.pricedCostUSD, 1.5)
    }

    func testClaudeFallsBackToAgentSummaryWhenChildTranscriptIsMissing() throws {
        let temp = try TempDirectory()
        let projectDirectory = temp.url.appendingPathComponent("project")
        let root = try temp.file(
            "project/root.jsonl",
            contents: """
            {"type":"user","uuid":"u1","timestamp":"2026-08-14T10:00:00Z","message":{"role":"user","content":"Delegate this"}}
            {"type":"assistant","uuid":"a1","timestamp":"2026-08-14T10:01:00Z","message":{"id":"m1","role":"assistant","model":"claude-sonnet-4-5","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"tool_use","id":"agent-call","name":"Agent","input":{}}]}}
            {"type":"user","uuid":"r1","timestamp":"2026-08-14T10:02:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"agent-call","content":"complete"}]},"toolUseResult":{"agentId":"missing-child","agentType":"researcher","resolvedModel":"claude-sonnet-4-5","status":"completed","totalTokens":1000000,"totalToolUseCount":3,"usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"iterations":2}}}
            """
        )

        let session = try XCTUnwrap(SessionLogParser.parse(
            claudeTranscriptDirs: [projectDirectory],
            claudeFiles: [root],
            codexFiles: [],
            pricing: testPricing()
        ).first)

        XCTAssertEqual(session.subagents.count, 1)
        XCTAssertEqual(session.subagents[0].dataCompleteness, .summaryOnly)
        XCTAssertEqual(session.subagents[0].ownUsage.modelInvocationCount, 2)
        assertDoubleEqual(session.subagents[0].ownUsage.pricedCostUSD, 3)
        XCTAssertEqual(session.toolCallCount, 4)
        XCTAssertEqual(session.dataCompleteness, .partial)
    }

    func testCodexBuildsSubagentTreeAndSeparatesTurnsFromInvocations() throws {
        let temp = try TempDirectory()
        let cwd = temp.url.appendingPathComponent("codex-app").path
        let root = try temp.file(
            "sessions/root.jsonl",
            contents: """
            {"timestamp":"2026-08-14T09:00:00Z","type":"session_meta","payload":{"id":"codex-root","session_id":"codex-root","thread_source":"user","cwd":"\(cwd)","git":{"branch":"main"}}}
            {"timestamp":"2026-08-14T09:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"<environment_context>hidden</environment_context> Ship the parser","text_elements":[]}}
            {"timestamp":"2026-08-14T09:00:02Z","type":"turn_context","payload":{"turn_id":"turn-1","cwd":"\(cwd)","model":"gpt-5-5"}}
            {"timestamp":"2026-08-14T09:00:03Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
            {"timestamp":"2026-08-14T09:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":250000,"cache_write_input_tokens":100000,"output_tokens":100000,"reasoning_output_tokens":20000,"total_tokens":1100000}}}}
            {"timestamp":"2026-08-14T09:00:05Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"exec-1","arguments":"{}"}}
            {"timestamp":"2026-08-14T09:00:06Z","type":"response_item","payload":{"type":"function_call_output","call_id":"exec-1","output":"12345678"}}
            {"timestamp":"2026-08-14T09:00:07Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"exec-1"}}}
            {"timestamp":"2026-08-14T09:00:08Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10000,"reasoning_output_tokens":1000,"total_tokens":110000}}}}
            {"timestamp":"2026-08-14T09:00:09Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":8019}}}}
            {"timestamp":"2026-08-14T09:00:10Z","type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"mcp-1","invocation":{"server":"notion","tool":"fetch","arguments":{}},"result":{"Ok":{"content":[{"type":"text","text":"abcdefgh"}],"isError":false}}}}
            {"timestamp":"2026-08-14T09:00:11Z","type":"response_item","payload":{"type":"web_search_call","id":"web-1","status":"completed"}}
            {"timestamp":"2026-08-14T09:00:12Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
            """
        )
        let child = try temp.file(
            "sessions/child.jsonl",
            contents: """
            {"timestamp":"2026-08-14T09:00:03Z","type":"session_meta","ordinal":0,"payload":{"id":"codex-child","session_id":"codex-child","thread_source":"subagent","parent_thread_id":"codex-root","subagent_history_start_ordinal":10,"agent_nickname":"worker","cwd":"\(cwd)","source":{"subagent":{"agent_role":"worker"}}}}
            {"timestamp":"2026-08-14T09:00:00Z","type":"session_meta","ordinal":1,"payload":{"id":"codex-root","session_id":"codex-root","thread_source":"user","cwd":"\(cwd)"}}
            {"timestamp":"2026-08-14T09:00:01Z","type":"event_msg","ordinal":2,"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":9000000}}}}
            {"timestamp":"2026-08-14T09:00:04Z","type":"turn_context","ordinal":10,"payload":{"turn_id":"child-turn","cwd":"\(cwd)","model":"gpt-5-5"}}
            {"timestamp":"2026-08-14T09:00:05Z","type":"event_msg","ordinal":11,"payload":{"type":"task_started","turn_id":"child-turn"}}
            {"timestamp":"2026-08-14T09:00:06Z","type":"event_msg","ordinal":12,"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":500000}}}}
            {"timestamp":"2026-08-14T09:00:07Z","type":"response_item","ordinal":13,"payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"patch-1","input":"{}"}}
            {"timestamp":"2026-08-14T09:00:08Z","type":"response_item","ordinal":14,"payload":{"type":"custom_tool_call_output","call_id":"patch-1","output":"done"}}
            {"timestamp":"2026-08-14T09:00:09Z","type":"event_msg","ordinal":15,"payload":{"type":"task_complete","turn_id":"child-turn"}}
            """
        )
        let pricing = testPricing([
            "gpt-5.5": TokenPricing(input: 5, output: 30, cacheWrite: 2, cacheRead: 0.5)
        ])

        let sessions = SessionLogParser.parse(
            claudeTranscriptDirs: [],
            claudeFiles: [],
            codexFiles: [root, child],
            pricing: pricing
        )

        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(session.id, UsageSessionID(harness: .codex, rawValue: "codex-root"))
        XCTAssertEqual(session.preview, "Ship the parser")
        XCTAssertEqual(session.repositoryName, "codex-app")
        XCTAssertEqual(session.gitBranch, "main")
        XCTAssertEqual(session.humanTurnCount, 1)
        XCTAssertEqual(session.ownUsage.modelInvocationCount, 3)
        XCTAssertEqual(session.modelInvocationCount, 4)
        XCTAssertEqual(session.inclusiveUsage.unpricedModelInvocationCount, 1)
        XCTAssertEqual(session.inclusiveUsage.tokens.reasoningOutputTokens, 21_000)
        XCTAssertEqual(session.inclusiveUsage.tokens.totalOnlyTokens, 8_019)
        assertDoubleEqual(session.ownUsage.pricedCostUSD, 7.375)
        assertDoubleEqual(session.inclusiveUsage.pricedCostUSD, 9.875)
        XCTAssertEqual(session.toolCallCount, 4)
        XCTAssertEqual(session.mcpCallCount, 1)
        XCTAssertEqual(session.tools.first(where: { $0.name == "exec_command" })?.callCount, 1)
        XCTAssertEqual(session.tools.first(where: { $0.name == "web_search" })?.resultTokens.quality, .unavailable)
        XCTAssertEqual(session.mcps.first?.resultTokens.value, 2)

        let subagent = try XCTUnwrap(session.subagents.first)
        XCTAssertEqual(subagent.id, "codex-child")
        XCTAssertEqual(subagent.name, "worker")
        XCTAssertEqual(subagent.kind, "worker")
        XCTAssertEqual(subagent.toolCallCount, 1)
        assertDoubleEqual(subagent.ownUsage.pricedCostUSD, 2.5)
    }

    func testIntervalSlicesMetricsButKeepsLifetimeMetadataAndPreview() throws {
        let temp = try TempDirectory()
        let file = try temp.file(
            "sessions/range.jsonl",
            contents: """
            {"timestamp":"2026-08-13T23:00:00Z","type":"session_meta","payload":{"id":"range-session","thread_source":"user","cwd":"/tmp/range-repo"}}
            {"timestamp":"2026-08-13T23:10:00Z","type":"event_msg","payload":{"type":"user_message","message":"Conversation topic","text_elements":[]}}
            {"timestamp":"2026-08-13T23:11:00Z","type":"turn_context","payload":{"turn_id":"old","model":"gpt-5-5"}}
            {"timestamp":"2026-08-13T23:12:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1000000}}}}
            {"timestamp":"2026-08-14T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"Follow up","text_elements":[]}}
            {"timestamp":"2026-08-14T01:01:00Z","type":"turn_context","payload":{"turn_id":"new","model":"gpt-5-5"}}
            {"timestamp":"2026-08-14T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":500000}}}}
            """
        )
        let start = try XCTUnwrap(ParserHelpers.parseISO8601("2026-08-14T00:00:00Z"))
        let end = try XCTUnwrap(ParserHelpers.parseISO8601("2026-08-15T00:00:00Z"))

        let session = try XCTUnwrap(SessionLogParser.parse(
            claudeTranscriptDirs: [],
            claudeFiles: [],
            codexFiles: [file],
            pricing: testPricing(),
            interval: DateInterval(start: start, end: end)
        ).first)

        XCTAssertEqual(session.preview, "Conversation topic")
        XCTAssertEqual(session.humanTurnCount, 1)
        XCTAssertEqual(session.modelInvocationCount, 1)
        XCTAssertEqual(session.inclusiveUsage.tokens.inputTokens, 500_000)
        assertDoubleEqual(session.inclusiveUsage.pricedCostUSD, 2.5)
        XCTAssertEqual(session.startedAt, ParserHelpers.parseISO8601("2026-08-13T23:00:00Z"))
        XCTAssertEqual(session.lastActivityAt, ParserHelpers.parseISO8601("2026-08-14T01:02:00Z"))
    }

    func testTiedSessionModelsUseStableIDOrdering() {
        let usage = SessionUsage(
            pricedCostUSD: 1,
            modelInvocationCount: 1
        )

        let models = sessionModelList(from: [
            "zeta": usage,
            "alpha": usage,
        ])

        XCTAssertEqual(models.map(\.id), ["alpha", "zeta"])
    }
}

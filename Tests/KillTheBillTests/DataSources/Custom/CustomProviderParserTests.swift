import Foundation
import XCTest
@testable import KillTheBill

final class CustomProviderParserTests: XCTestCase {
    func testCustomProviderParsesMatchingJsonlEvents() throws {
        let temp = try TempDirectory()
        let log = """
        {"event_name":"gemini_api_response","workspace":"client-app","model":"models/gemini-2.5-pro","usage_metadata":{"prompt_token_count":1000000,"candidates_token_count":100000,"cached_content_token_count":100000,"total_token_count":1200000}}
        {"event_name":"ignored","workspace":"client-app","model":"models/gemini-2.5-pro","usage_metadata":{"prompt_token_count":1,"candidates_token_count":1,"total_token_count":2}}
        """
        let file = try temp.file("logs/today.jsonl", contents: log)
        let provider = makeProvider(root: file.deletingLastPathComponent().path)

        let usage = CustomProviderParser.parseProviders([provider: [file]], pricing: testPricing())

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.turnCount, 1)
        XCTAssertEqual(usage.inputTokens, 1_000_000)
        XCTAssertEqual(usage.outputTokens, 100_000)
        XCTAssertEqual(usage.cacheReadTokens, 100_000)
        XCTAssertEqual(usage.perWorkspace.first?.displayName, "client-app")
        XCTAssertEqual(usage.perModel.first?.id, "gemini-2.5-pro")
        assertDoubleEqual(usage.totalCostUSD, 2.2625)
    }

    func testFindTodayFilesHonorsRootsExtensionsAndRecursion() throws {
        let temp = try TempDirectory()
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        let todayFile = try temp.file("logs/nested/today.jsonl", contents: "{}", modifiedAt: today)
        _ = try temp.file("logs/nested/old.jsonl", contents: "{}", modifiedAt: yesterday)
        _ = try temp.file("logs/nested/ignored.txt", contents: "{}", modifiedAt: today)

        let provider = makeProvider(root: temp.url.appendingPathComponent("logs").path)
        let files = CustomProviderParser.findTodayFiles(for: [provider])

        XCTAssertEqual(files[provider], [todayFile])
    }

    func testCountMonthlyTurnsUsesConfiguredTotalTokenPath() throws {
        let temp = try TempDirectory()
        let log = """
        {"event_name":"gemini_api_response","usage_metadata":{"total_token_count":10}}
        {"event_name":"other","usage_metadata":{"total_token_count":10}}
        {"event_name":"gemini_api_response","usage_metadata":{"total_token_count":0}}
        """
        let file = try temp.file("logs/today.jsonl", contents: log)
        let provider = makeProvider(root: file.deletingLastPathComponent().path)

        XCTAssertEqual(CustomProviderParser.countMonthlyTurns([provider: [file]]), 1)
    }

    private func makeProvider(root: String) -> CustomProviderConfig {
        CustomProviderConfig(
            id: "gemini",
            name: "Gemini",
            files: CustomProviderFiles(roots: [root], recursive: true, extensions: ["jsonl"]),
            event: CustomProviderEvent(
                matches: [CustomProviderMatch(path: ["event_name"], equals: "gemini_api_response")],
                workspacePath: ["workspace"],
                workspaceDefault: "Gemini",
                modelPath: ["model"],
                modelDefault: "gemini-2.5-pro",
                inputTokensPath: ["usage_metadata", "prompt_token_count"],
                outputTokensPath: ["usage_metadata", "candidates_token_count"],
                cacheReadTokensPath: ["usage_metadata", "cached_content_token_count"],
                cacheWriteTokensPath: nil,
                totalTokensPath: ["usage_metadata", "total_token_count"]
            ),
            pricing: nil
        )
    }
}

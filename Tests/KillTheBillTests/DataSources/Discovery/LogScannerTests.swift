import Foundation
import XCTest
@testable import KillTheBill

final class LogScannerTests: XCTestCase {
    func testProjectNameDecodesClaudeProjectDirectory() {
        XCTAssertEqual(LogScanner.projectName(from: "-Users-diogor-Projetos-kill-the-bill"), "kill-the-bill")
    }

    func testProjectNameFallsBackToRawDirectoryWhenNoProjectPartsExist() {
        XCTAssertEqual(LogScanner.projectName(from: "---"), "---")
    }

    func testSourceCountIncludesNativeHarnessLocations() {
        let sources = LogScanner.DiscoveredSources(
            claudeTranscriptDirs: [URL(fileURLWithPath: "/one"), URL(fileURLWithPath: "/two")],
            codexSessionRoot: URL(fileURLWithPath: "/codex")
        )

        XCTAssertEqual(sources.sourceCount, 3)
    }

    func testFindAllClaudeTranscriptsRecursesWithoutDateFiltering() throws {
        let temp = try TempDirectory()
        let oldDate = Date(timeIntervalSince1970: 1)
        let later = try temp.file("project/nested/zeta.jsonl", contents: "{}", modifiedAt: oldDate)
        let earlier = try temp.file("project/nested/alpha.jsonl", contents: "{}", modifiedAt: oldDate)
        _ = try temp.file("project/nested/ignored.txt", contents: "{}", modifiedAt: oldDate)

        let files = LogScanner.findAllClaudeTranscripts(
            from: [temp.url.appendingPathComponent("project")]
        )

        XCTAssertEqual(
            files.map { $0.resolvingSymlinksInPath().path },
            [earlier, later].map { $0.resolvingSymlinksInPath().path }
        )
    }

    func testFindAllCodexSessionsRecursesWithoutDateFiltering() throws {
        let temp = try TempDirectory()
        let oldDate = Date(timeIntervalSince1970: 1)
        let later = try temp.file("sessions/2020/01/zeta.jsonl", contents: "{}", modifiedAt: oldDate)
        let earlier = try temp.file("sessions/2020/01/alpha.jsonl", contents: "{}", modifiedAt: oldDate)

        let files = LogScanner.findAllCodexSessions(
            from: temp.url.appendingPathComponent("sessions")
        )

        XCTAssertEqual(
            files.map { $0.resolvingSymlinksInPath().path },
            [earlier, later].map { $0.resolvingSymlinksInPath().path }
        )
    }
}

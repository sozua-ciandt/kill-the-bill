import XCTest
@testable import KillTheBill

final class LogScannerTests: XCTestCase {
    func testProjectNameDecodesClaudeProjectDirectory() {
        XCTAssertEqual(LogScanner.projectName(from: "-Users-diogor-Projetos-kill-the-bill"), "kill-the-bill")
    }

    func testProjectNameFallsBackToRawDirectoryWhenNoProjectPartsExist() {
        XCTAssertEqual(LogScanner.projectName(from: "---"), "---")
    }
}

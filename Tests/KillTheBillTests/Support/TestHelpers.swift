import Foundation
import XCTest
@testable import KillTheBill

final class TempDirectory {
    let url: URL

    init(name: String = UUID().uuidString) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KillTheBillTests")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ relativePath: String, contents: String, modifiedAt: Date = Date()) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        return file
    }
}

func testPricing(_ entries: [String: TokenPricing] = [
    "claude-sonnet-4-5": TokenPricing(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30),
    "gpt-5.5": TokenPricing(input: 5, output: 30, cacheWrite: 0, cacheRead: 0.50),
    "gemini-2.5-pro": TokenPricing(input: 1.25, output: 10, cacheWrite: 0, cacheRead: 0.125),
]) -> ModelPricing {
    ModelPricing(models: entries)
}

func assertDoubleEqual(
    _ actual: Double,
    _ expected: Double,
    accuracy: Double = 0.000001,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual, expected, accuracy: accuracy, file: file, line: line)
}

import Foundation
import XCTest
@testable import KillTheBill

final class AppVersionTests: XCTestCase {
    func testReadsVersionAndBuildFromInfoDictionary() {
        let version = AppVersion.from(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        ])

        XCTAssertEqual(version.shortVersion, "1.2.3")
        XCTAssertEqual(version.build, "42")
        XCTAssertEqual(version.displayName, "v1.2.3")
        XCTAssertEqual(version.detailedDisplayName, "v1.2.3 (42)")
    }

    func testFallsBackWhenBundleVersionIsMissing() {
        let version = AppVersion.from(infoDictionary: nil)

        XCTAssertEqual(version.shortVersion, "0.0.0")
        XCTAssertNil(version.build)
        XCTAssertEqual(version.detailedDisplayName, "v0.0.0")
    }
}

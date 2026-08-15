import Foundation
import XCTest
@testable import KillTheBill

final class DistributionTests: XCTestCase {
    func testInfoPlistIdentityAndVersionAreValid() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            info["CFBundleIdentifier"] as? String,
            "dev.sozua-ciandt.kill-the-bill"
        )
        XCTAssertNotNil(SemanticVersion(try XCTUnwrap(info["CFBundleShortVersionString"] as? String)))
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertNotNil(UInt64(build))
    }

    func testInstallerConsumesValidatedReleaseAssetWithoutBuildingSource() throws {
        let installer = try source("install.sh")

        XCTAssertTrue(installer.contains("releases/latest/download/$APP_NAME.app.zip"))
        XCTAssertTrue(installer.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(installer.contains("spctl --assess --type execute"))
        XCTAssertTrue(installer.contains("EXPECTED_BUNDLE_ID"))
        XCTAssertFalse(installer.contains("swift build"))
        XCTAssertFalse(installer.contains("xattr -dr com.apple.quarantine"))

        let duplicatePreflight = try XCTUnwrap(
            installer.range(of: "preflight_known_app_removal \"$duplicate_app\"")
        )
        let installation = try XCTUnwrap(
            installer.range(of: "install_transactionally \"$candidate\" \"$install_dir\"")
        )
        let duplicateRemoval = try XCTUnwrap(
            installer.range(of: "safe_remove_known_app \"$user_app\"")
        )
        XCTAssertLessThan(duplicatePreflight.lowerBound, installation.lowerBound)
        XCTAssertLessThan(installation.lowerBound, duplicateRemoval.lowerBound)
    }

    func testBundleIncludesSwiftPMResourcesAndReleasePublishesLast() throws {
        let makefile = try source("Makefile")
        XCTAssertTrue(makefile.contains("KillTheBill_KillTheBill.bundle"))
        XCTAssertTrue(makefile.contains("codesign --verify --deep --strict"))

        let workflow = try source(".github/workflows/release.yml")
        let validation = try XCTUnwrap(workflow.range(of: "Validate final distributable"))
        let draft = try XCTUnwrap(workflow.range(of: "Create draft release with validated assets"))
        let publish = try XCTUnwrap(workflow.range(of: "Publish release as latest"))
        XCTAssertLessThan(validation.lowerBound, draft.lowerBound)
        XCTAssertLessThan(draft.lowerBound, publish.lowerBound)
        XCTAssertFalse(workflow.contains("publishing source-only release"))
    }

    func testShellScriptsParseAndRemainExecutable() throws {
        for name in ["install.sh", "uninstall.sh"] {
            let url = repositoryRoot.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", url.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(name) must parse as bash")

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertNotEqual(permissions & 0o111, 0, "\(name) must be executable")
        }
    }

    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

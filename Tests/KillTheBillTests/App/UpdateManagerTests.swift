import CryptoKit
import Foundation
import XCTest
@testable import KillTheBill

final class SemanticVersionTests: XCTestCase {
    func testParsesTagPrefixPrereleaseAndBuildMetadata() throws {
        let version = try XCTUnwrap(SemanticVersion("v2.10.3-rc.2+build.45"))

        XCTAssertEqual(version.description, "2.10.3-rc.2+build.45")
        XCTAssertEqual(version.major, 2)
        XCTAssertEqual(version.minor, 10)
        XCTAssertEqual(version.patch, 3)
    }

    func testUsesSemVerPrecedenceRules() throws {
        let ordered = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ].compactMap(SemanticVersion.init)

        XCTAssertEqual(ordered, ordered.sorted())
        XCTAssertEqual(SemanticVersion("1.0.0+one"), SemanticVersion("1.0.0+two"))
    }

    func testRejectsMalformedAndNonASCIIVersions() {
        XCTAssertNil(SemanticVersion("1.2"))
        XCTAssertNil(SemanticVersion("1.02.3"))
        XCTAssertNil(SemanticVersion("1.2.3-01"))
        XCTAssertNil(SemanticVersion("1.2.3-β"))
        XCTAssertNil(SemanticVersion("release-1.2.3"))
    }
}

@MainActor
final class UpdateManagerTests: XCTestCase {
    func testCheckUsesGitHubHeadersAndFindsStableRelease() async throws {
        let response = try releaseResponse(version: "v0.5.0", archive: Data("zip".utf8))
        let client = StubUpdateHTTPClient(responses: [response])
        let fixture = try UpdateFixture()
        let manager = makeManager(client: client, fixture: fixture)

        await manager.checkNowAndWait()

        XCTAssertEqual(manager.state, .available)
        XCTAssertEqual(manager.availableRelease?.version, SemanticVersion("0.5.0"))
        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "KillTheBill/0.4.2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testIgnoresDraftAndPrereleaseResponses() async throws {
        for flags in [(draft: true, prerelease: false), (draft: false, prerelease: true)] {
            let response = try releaseResponse(
                version: "v9.0.0",
                archive: Data("zip".utf8),
                draft: flags.draft,
                prerelease: flags.prerelease
            )
            let fixture = try UpdateFixture()
            let manager = makeManager(
                client: StubUpdateHTTPClient(responses: [response]),
                fixture: fixture
            )

            await manager.checkNowAndWait()

            XCTAssertEqual(manager.state, .upToDate)
            XCTAssertNil(manager.availableRelease)
        }
    }

    func testReportsMissingReleaseAsset() async throws {
        let response = try releaseResponse(
            version: "v0.5.0",
            archive: Data("zip".utf8),
            assetName: "source.zip"
        )
        let fixture = try UpdateFixture()
        let manager = makeManager(
            client: StubUpdateHTTPClient(responses: [response]),
            fixture: fixture
        )

        await manager.checkNowAndWait()

        XCTAssertEqual(manager.state, .error)
        XCTAssertTrue(manager.errorMessage?.contains(UpdateManager.releaseAssetName) == true)
    }

    func testExplicitInstallDownloadsValidatesReplacesAndRelaunches() async throws {
        let archive = Data("fixture archive".utf8)
        let apiResponse = try releaseResponse(version: "v0.5.0", archive: archive)
        let downloadResponse = try httpResponse(data: archive, url: assetURL)
        let client = StubUpdateHTTPClient(responses: [apiResponse, downloadResponse])
        let fixture = try UpdateFixture()
        let appController = FakeUpdateApplicationController()
        let manager = makeManager(
            client: client,
            fixture: fixture,
            applicationController: appController
        )

        await manager.checkNowAndWait()
        await manager.installAvailableUpdateAndWait()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.stagedUpdate)
        XCTAssertEqual(
            appController.relaunchedURL.map { ($0.standardizedFileURL.path as NSString).standardizingPath },
            (fixture.currentApplicationURL.standardizedFileURL.path as NSString).standardizingPath
        )
        XCTAssertTrue(appController.didTerminate)
        let installedMarker = fixture.currentApplicationURL
            .appendingPathComponent("Contents/Resources/marker.txt")
        XCTAssertEqual(try String(contentsOf: installedMarker, encoding: .utf8), "new")
    }

    func testDigestMismatchStopsBeforeExtraction() async throws {
        let archive = Data("fixture archive".utf8)
        let response = try releaseResponse(
            version: "v0.5.0",
            archive: archive,
            digest: "sha256:" + String(repeating: "0", count: 64)
        )
        let download = try httpResponse(data: archive, url: assetURL)
        let fixture = try UpdateFixture()
        let manager = makeManager(
            client: StubUpdateHTTPClient(responses: [response, download]),
            fixture: fixture
        )

        await manager.checkNowAndWait()
        await manager.installAvailableUpdateAndWait()

        XCTAssertEqual(manager.state, .error)
        XCTAssertTrue(manager.errorMessage?.contains("SHA-256") == true)
    }

    func testAutomaticCheckPersistsAttemptAndDoesNotRepeatOnRelaunch() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = try makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        defaults.set(
            now.addingTimeInterval(-UpdateManager.defaultAutomaticCheckInterval - 1)
                .timeIntervalSince1970,
            forKey: UpdateManager.automaticCheckTimestampKey
        )
        let response = try releaseResponse(version: "v0.5.0", archive: Data("zip".utf8))
        let client = StubUpdateHTTPClient(responses: [response])
        let fixture = try UpdateFixture()
        let manager = makeManager(
            client: client,
            fixture: fixture,
            automaticCheckDefaults: defaults,
            now: { now }
        )

        manager.start(automaticChecksEnabled: true)
        await client.waitForRequestCount(1)

        let initialRequestCount = await client.requests.count
        XCTAssertEqual(initialRequestCount, 1)
        XCTAssertEqual(
            defaults.double(forKey: UpdateManager.automaticCheckTimestampKey),
            now.timeIntervalSince1970
        )
        manager.stop()

        let relaunchedClient = StubUpdateHTTPClient(responses: [])
        let relaunchedManager = makeManager(
            client: relaunchedClient,
            fixture: fixture,
            automaticCheckDefaults: defaults,
            now: { now.addingTimeInterval(60) }
        )
        relaunchedManager.start(automaticChecksEnabled: true)

        let relaunchedRequestCount = await relaunchedClient.requests.count
        XCTAssertEqual(relaunchedRequestCount, 0)
        XCTAssertEqual(relaunchedManager.state, .idle)
        relaunchedManager.stop()
    }

    func testManualCheckIgnoresRecentAutomaticCheckTimestamp() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let defaults = try makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        defaults.set(
            now.timeIntervalSince1970,
            forKey: UpdateManager.automaticCheckTimestampKey
        )
        let response = try releaseResponse(version: "v0.5.0", archive: Data("zip".utf8))
        let client = StubUpdateHTTPClient(responses: [response])
        let fixture = try UpdateFixture()
        let manager = makeManager(
            client: client,
            fixture: fixture,
            automaticCheckDefaults: defaults,
            now: { now }
        )

        await manager.checkNowAndWait()

        let requestCount = await client.requests.count
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(manager.state, .available)
    }

    private let apiURL = UpdateManager.defaultReleaseAPIURL
    private let assetURL = URL(
        string: "https://github.com/sozua-ciandt/kill-the-bill/releases/download/v0.5.0/KillTheBill.app.zip"
    )!

    private func makeManager(
        client: StubUpdateHTTPClient,
        fixture: UpdateFixture,
        applicationController: FakeUpdateApplicationController = FakeUpdateApplicationController(),
        automaticCheckDefaults: UserDefaults = .standard,
        now: @escaping @MainActor @Sendable () -> Date = Date.init
    ) -> UpdateManager {
        UpdateManager(
            httpClient: client,
            archiveExtractor: FixtureArchiveExtractor(sourceApplicationURL: fixture.newApplicationURL),
            bundleValidator: AcceptingUpdateBundleValidator(),
            applicationController: applicationController,
            releaseAPIURL: apiURL,
            currentVersionString: "0.4.2",
            currentApplicationURL: fixture.currentApplicationURL,
            expectedBundleIdentifier: UpdateFixture.bundleIdentifier,
            stagingRoot: fixture.temp.url.appendingPathComponent("Updates"),
            automaticCheckDefaults: automaticCheckDefaults,
            now: now
        )
    }

    private func makeEphemeralDefaults() throws -> UserDefaults {
        let name = "KillTheBillTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(name, forKey: "testSuiteName")
        return defaults
    }

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: "testSuiteName")!
    }

    private func releaseResponse(
        version: String,
        archive: Data,
        assetName: String = UpdateManager.releaseAssetName,
        draft: Bool = false,
        prerelease: Bool = false,
        digest: String? = nil
    ) throws -> (Data, URLResponse) {
        var asset: [String: Any] = [
            "name": assetName,
            "browser_download_url": assetURL.absoluteString,
            "size": archive.count,
        ]
        if let digest { asset["digest"] = digest }
        let json: [String: Any] = [
            "tag_name": version,
            "name": "Kill the Bill \(version)",
            "body": "Release notes",
            "draft": draft,
            "prerelease": prerelease,
            "html_url": "https://github.com/sozua-ciandt/kill-the-bill/releases/tag/\(version)",
            "assets": [asset],
        ]
        return try httpResponse(data: JSONSerialization.data(withJSONObject: json), url: apiURL)
    }

    private func httpResponse(data: Data, url: URL) throws -> (Data, URLResponse) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (data, response)
    }
}

@MainActor
final class DeveloperIDUpdateBundleValidatorTests: XCTestCase {
    func testAllowsOneTimeBootstrapFromAdHocToNotarizedDeveloperID() async throws {
        let fixture = try UpdateFixture()
        let runner = SignatureCommandRunner(currentTeamIdentifier: nil, newTeamIdentifier: "TEAM123")
        let validator = DeveloperIDUpdateBundleValidator(runner: runner)

        let validated = try await validator.validate(
            applicationURL: fixture.newApplicationURL,
            for: fixture.release,
            currentApplicationURL: fixture.currentApplicationURL,
            expectedBundleIdentifier: UpdateFixture.bundleIdentifier
        )

        XCTAssertEqual(validated.teamIdentifier, "TEAM123")
        XCTAssertEqual(validated.version, SemanticVersion("0.5.0"))
    }

    func testRejectsDeveloperTeamChangeAfterBootstrap() async throws {
        let fixture = try UpdateFixture()
        let runner = SignatureCommandRunner(
            currentTeamIdentifier: "OLDTEAM",
            newTeamIdentifier: "NEWTEAM"
        )
        let validator = DeveloperIDUpdateBundleValidator(runner: runner)

        do {
            _ = try await validator.validate(
                applicationURL: fixture.newApplicationURL,
                for: fixture.release,
                currentApplicationURL: fixture.currentApplicationURL,
                expectedBundleIdentifier: UpdateFixture.bundleIdentifier
            )
            XCTFail("Expected a signer mismatch")
        } catch let failure as UpdateFailure {
            guard case .untrustedBundle(let message) = failure else {
                return XCTFail("Unexpected failure: \(failure)")
            }
            XCTAssertTrue(message.contains("Developer Team changed"))
        }
    }

    func testRejectsInvalidCurrentSignatureInsteadOfTreatingItAsAdHoc() async throws {
        let fixture = try UpdateFixture()
        let runner = SignatureCommandRunner(
            currentTeamIdentifier: nil,
            newTeamIdentifier: "TEAM123",
            currentSignatureIsValid: false
        )
        let validator = DeveloperIDUpdateBundleValidator(runner: runner)

        do {
            _ = try await validator.validate(
                applicationURL: fixture.newApplicationURL,
                for: fixture.release,
                currentApplicationURL: fixture.currentApplicationURL,
                expectedBundleIdentifier: UpdateFixture.bundleIdentifier
            )
            XCTFail("Expected an invalid current signature to be rejected")
        } catch let failure as UpdateFailure {
            guard case .untrustedBundle(let message) = failure else {
                return XCTFail("Unexpected failure: \(failure)")
            }
            XCTAssertTrue(message.contains("installed app has an invalid code signature"))
        }
    }
}

private actor StubUpdateHTTPClient: UpdateHTTPClient {
    private var responses: [(Data, URLResponse)]
    private(set) var requests: [URLRequest] = []
    private var requestWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    init(responses: [(Data, URLResponse)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        resumeSatisfiedWaiters()
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in requestWaiters {
            if requests.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestWaiters = remaining
    }
}

private struct FixtureArchiveExtractor: UpdateArchiveExtracting {
    let sourceApplicationURL: URL

    func extract(archive: URL, into directory: URL) async throws {
        try FileManager.default.copyItem(
            at: sourceApplicationURL,
            to: directory.appendingPathComponent("KillTheBill.app")
        )
    }
}

private struct AcceptingUpdateBundleValidator: UpdateBundleValidating {
    func validate(
        applicationURL: URL,
        for release: UpdateRelease,
        currentApplicationURL: URL,
        expectedBundleIdentifier: String
    ) async throws -> ValidatedUpdateBundle {
        ValidatedUpdateBundle(
            applicationURL: applicationURL,
            version: release.version,
            teamIdentifier: "TEAM123"
        )
    }
}

@MainActor
private final class FakeUpdateApplicationController: UpdateApplicationControlling {
    private(set) var relaunchedURL: URL?
    private(set) var didTerminate = false

    func relaunch(applicationAt url: URL) async throws {
        relaunchedURL = url
    }

    func terminateCurrentApplication() {
        didTerminate = true
    }
}

private struct SignatureCommandRunner: UpdateCommandRunning {
    let currentTeamIdentifier: String?
    let newTeamIdentifier: String
    var currentSignatureIsValid = true

    func run(executable: URL, arguments: [String]) async throws -> UpdateCommandResult {
        if executable.path == "/usr/sbin/spctl" {
            return UpdateCommandResult(terminationStatus: 0, output: "accepted")
        }
        if arguments.first == "--verify" {
            let isCurrent = arguments.last?.contains("Current/KillTheBill.app") == true
            return UpdateCommandResult(
                terminationStatus: isCurrent && !currentSignatureIsValid ? 1 : 0,
                output: isCurrent && !currentSignatureIsValid ? "invalid signature" : "accepted"
            )
        }
        if executable.path == "/usr/bin/codesign", arguments.first == "-dv" {
            let isCurrent = arguments.last?.contains("Current/KillTheBill.app") == true
            if isCurrent, let currentTeamIdentifier {
                return signatureOutput(teamIdentifier: currentTeamIdentifier)
            }
            if isCurrent {
                return UpdateCommandResult(
                    terminationStatus: 0,
                    output: "Signature=adhoc\nTeamIdentifier=not set\n"
                )
            }
            return signatureOutput(teamIdentifier: newTeamIdentifier)
        }
        return UpdateCommandResult(terminationStatus: 1, output: "unexpected command")
    }

    private func signatureOutput(teamIdentifier: String) -> UpdateCommandResult {
        UpdateCommandResult(
            terminationStatus: 0,
            output: "Authority=Developer ID Application: Example (\(teamIdentifier))\n"
                + "TeamIdentifier=\(teamIdentifier)\n"
        )
    }
}

private final class UpdateFixture {
    static let bundleIdentifier = "dev.sozua-ciandt.kill-the-bill"

    let temp: UpdaterTempDirectory
    let currentApplicationURL: URL
    let newApplicationURL: URL

    init() throws {
        temp = try UpdaterTempDirectory()
        currentApplicationURL = temp.url.appendingPathComponent("Current/KillTheBill.app")
        newApplicationURL = temp.url.appendingPathComponent("Fixture/KillTheBill.app")
        try Self.makeApplication(at: currentApplicationURL, version: "0.4.2", marker: "old")
        try Self.makeApplication(at: newApplicationURL, version: "0.5.0", marker: "new")
    }

    var release: UpdateRelease {
        UpdateRelease(
            tagName: "v0.5.0",
            version: SemanticVersion("0.5.0")!,
            name: "Kill the Bill v0.5.0",
            notes: "",
            pageURL: URL(string: "https://example.com/release")!,
            downloadURL: URL(string: "https://example.com/app.zip")!,
            assetSize: 1,
            assetDigest: nil
        )
    }

    private static func makeApplication(at url: URL, version: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents")
        let executableDirectory = contents.appendingPathComponent("MacOS")
        let resourcesDirectory = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: resourcesDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: resourcesDirectory.appendingPathComponent("KillTheBill_KillTheBill.bundle"),
            withIntermediateDirectories: false
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version == "0.5.0" ? "10" : "9",
            "CFBundleExecutable": "KillTheBill",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        let executableURL = executableDirectory.appendingPathComponent("KillTheBill")
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        try marker.write(
            to: resourcesDirectory.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private final class UpdaterTempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KillTheBillUpdaterTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

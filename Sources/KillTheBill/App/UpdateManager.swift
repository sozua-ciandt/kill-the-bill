import AppKit
import CryptoKit
import Foundation
import Observation

// MARK: - Versions

/// A SemVer 2.0 version used to compare the installed app with GitHub release
/// tags. Build metadata is intentionally ignored during ordering.
struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    private enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(String)
        case alphaNumeric(String)

        var value: String {
            switch self {
            case .numeric(let value), .alphaNumeric(let value): value
            }
        }
    }

    let major: UInt64
    let minor: UInt64
    let patch: UInt64
    private let prerelease: [PrereleaseIdentifier]
    private let build: [String]

    static let zero = SemanticVersion(major: 0, minor: 0, patch: 0)

    init(major: UInt64, minor: UInt64, patch: UInt64) {
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = []
        build = []
    }

    init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        let buildParts = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !buildParts[0].isEmpty else { return nil }

        let versionParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.parseCoreNumber(core[0]),
              let minor = Self.parseCoreNumber(core[1]),
              let patch = Self.parseCoreNumber(core[2]) else {
            return nil
        }

        var prerelease: [PrereleaseIdentifier] = []
        if versionParts.count == 2 {
            let identifiers = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { return nil }
            for identifierSlice in identifiers {
                let identifier = String(identifierSlice)
                guard Self.isValidIdentifier(identifier) else { return nil }
                if identifier.unicodeScalars.allSatisfy(Self.isASCIIDigit) {
                    guard identifier == "0" || !identifier.hasPrefix("0") else { return nil }
                    prerelease.append(.numeric(identifier))
                } else {
                    prerelease.append(.alphaNumeric(identifier))
                }
            }
        }

        var build: [String] = []
        if buildParts.count == 2 {
            let identifiers = buildParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { return nil }
            build = identifiers.map(String.init)
            guard build.allSatisfy(Self.isValidIdentifier) else { return nil }
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    var description: String {
        var result = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            result += "-" + prerelease.map(\.value).joined(separator: ".")
        }
        if !build.isEmpty {
            result += "+" + build.joined(separator: ".")
        }
        return result
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let leftCore = (lhs.major, lhs.minor, lhs.patch)
        let rightCore = (rhs.major, rhs.minor, rhs.patch)
        if leftCore != rightCore {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }

        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (left, right) {
            case (.numeric, .alphaNumeric):
                return true
            case (.alphaNumeric, .numeric):
                return false
            case (.numeric(let left), .numeric(let right)):
                if left.count != right.count { return left.count < right.count }
                return left < right
            case (.alphaNumeric(let left), .alphaNumeric(let right)):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func parseCoreNumber(_ value: Substring) -> UInt64? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy(isASCIIDigit),
              value == "0" || !value.hasPrefix("0") else {
            return nil
        }
        return UInt64(value)
    }

    private static func isValidIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.unicodeScalars.allSatisfy { scalar in
            isASCIIDigit(scalar)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar.value == 45
        }
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }
}

// MARK: - Public update state

struct UpdateRelease: Equatable, Identifiable, Sendable {
    let tagName: String
    let version: SemanticVersion
    let name: String
    let notes: String
    let pageURL: URL
    let downloadURL: URL
    let assetSize: Int64
    let assetDigest: String?

    var id: String { tagName }
}

struct StagedUpdate: Equatable, Sendable {
    enum InstallationCapability: Equatable, Sendable {
        case inPlace
        case requiresExternalInstaller(reason: String)
    }

    let release: UpdateRelease
    let applicationURL: URL
    let archiveURL: URL
    let workingDirectory: URL
    let teamIdentifier: String
    let installationCapability: InstallationCapability
}

enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case available
    case downloading
    case ready
    case installing
    case upToDate
    case error
}

enum UpdateFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidCurrentVersion(String)
    case invalidServerResponse
    case httpStatus(Int)
    case network(String)
    case invalidRelease(String)
    case missingReleaseAsset(String)
    case downloadSizeMismatch(expected: Int64, actual: Int64)
    case downloadDigestMismatch
    case extractionFailed(String)
    case invalidBundle(String)
    case untrustedBundle(String)
    case installationRequiresExternalInstaller(String)
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion(let version):
            "The installed app version is invalid: \(version)."
        case .invalidServerResponse:
            "GitHub returned an invalid update response."
        case .httpStatus(let status):
            "GitHub returned HTTP status \(status)."
        case .network(let message):
            "The update request failed: \(message)"
        case .invalidRelease(let reason):
            "The latest GitHub release is invalid: \(reason)"
        case .missingReleaseAsset(let name):
            "The latest release does not contain \(name)."
        case .downloadSizeMismatch(let expected, let actual):
            "The update download has the wrong size (expected \(expected), received \(actual))."
        case .downloadDigestMismatch:
            "The update download failed its SHA-256 integrity check."
        case .extractionFailed(let message):
            "The update could not be extracted: \(message)"
        case .invalidBundle(let message):
            "The downloaded app is invalid: \(message)"
        case .untrustedBundle(let message):
            "The downloaded app could not be trusted: \(message)"
        case .installationRequiresExternalInstaller(let message):
            message
        case .installationFailed(let message):
            "The update could not be installed: \(message)"
        }
    }
}

// MARK: - Injectable system boundaries

protocol UpdateHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionUpdateHTTPClient: UpdateHTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

struct UpdateCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let output: String
}

protocol UpdateCommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> UpdateCommandResult
}

struct SystemUpdateCommandRunner: UpdateCommandRunning {
    func run(executable: URL, arguments: [String]) async throws -> UpdateCommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return UpdateCommandResult(
                terminationStatus: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        }.value
    }
}

protocol UpdateArchiveExtracting: Sendable {
    func extract(archive: URL, into directory: URL) async throws
}

struct DittoUpdateArchiveExtractor: UpdateArchiveExtracting {
    let runner: any UpdateCommandRunning

    func extract(archive: URL, into directory: URL) async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, directory.path]
        )
        guard result.terminationStatus == 0 else {
            throw UpdateFailure.extractionFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

struct ValidatedUpdateBundle: Equatable, Sendable {
    let applicationURL: URL
    let version: SemanticVersion
    let teamIdentifier: String
}

protocol UpdateBundleValidating: Sendable {
    func validate(
        applicationURL: URL,
        for release: UpdateRelease,
        currentApplicationURL: URL,
        expectedBundleIdentifier: String
    ) async throws -> ValidatedUpdateBundle
}

struct DeveloperIDUpdateBundleValidator: UpdateBundleValidating, @unchecked Sendable {
    let runner: any UpdateCommandRunning
    let fileManager: FileManager

    init(
        runner: any UpdateCommandRunning = SystemUpdateCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    func validate(
        applicationURL: URL,
        for release: UpdateRelease,
        currentApplicationURL: URL,
        expectedBundleIdentifier: String
    ) async throws -> ValidatedUpdateBundle {
        let values = try applicationURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw UpdateFailure.invalidBundle("KillTheBill.app is not a regular application directory.")
        }

        let info = try Self.readInfoPlist(applicationURL: applicationURL)
        guard info.bundleIdentifier == expectedBundleIdentifier else {
            throw UpdateFailure.invalidBundle(
                "unexpected bundle identifier \(info.bundleIdentifier ?? "missing")"
            )
        }
        guard let versionString = info.shortVersion,
              let version = SemanticVersion(versionString),
              version >= release.version else {
            throw UpdateFailure.invalidBundle(
                "version must be at least \(release.version.description)"
            )
        }
        guard let executableName = info.executable,
              !executableName.isEmpty,
              executableName == URL(fileURLWithPath: executableName).lastPathComponent else {
            throw UpdateFailure.invalidBundle("CFBundleExecutable is missing or unsafe.")
        }

        let executableURL = applicationURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw UpdateFailure.invalidBundle("the main executable is missing or is not executable.")
        }

        let resourceBundleURL = applicationURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent("KillTheBill_KillTheBill.bundle", isDirectory: true)
        let resourceValues = try? resourceBundleURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard resourceValues?.isDirectory == true,
              resourceValues?.isSymbolicLink != true else {
            throw UpdateFailure.invalidBundle("the SwiftPM resource bundle is missing or unsafe.")
        }

        let signatureCheck = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", applicationURL.path]
        )
        guard signatureCheck.terminationStatus == 0 else {
            throw UpdateFailure.untrustedBundle(
                signatureCheck.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let signatureDetails = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", "--verbose=4", applicationURL.path]
        )
        guard signatureDetails.terminationStatus == 0,
              signatureDetails.output.contains("Authority=Developer ID Application:"),
              let newTeamIdentifier = Self.teamIdentifier(from: signatureDetails.output) else {
            throw UpdateFailure.untrustedBundle("a Developer ID Application signature is required.")
        }

        let gatekeeperCheck = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", "--verbose=4", applicationURL.path]
        )
        guard gatekeeperCheck.terminationStatus == 0 else {
            throw UpdateFailure.untrustedBundle(
                gatekeeperCheck.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Existing versions were built locally and ad-hoc signed. That one-time
        // bootstrap is accepted only because the new app independently passes
        // Developer ID and Gatekeeper checks above. Once a Developer ID build is
        // installed, every subsequent update must retain the same Team ID.
        if let currentTeamIdentifier = try await currentTeamIdentifier(at: currentApplicationURL),
           currentTeamIdentifier != newTeamIdentifier {
            throw UpdateFailure.untrustedBundle(
                "Developer Team changed from \(currentTeamIdentifier) to \(newTeamIdentifier)."
            )
        }

        return ValidatedUpdateBundle(
            applicationURL: applicationURL,
            version: version,
            teamIdentifier: newTeamIdentifier
        )
    }

    private func currentTeamIdentifier(at applicationURL: URL) async throws -> String? {
        guard fileManager.fileExists(atPath: applicationURL.path) else { return nil }

        let verification = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", applicationURL.path]
        )
        guard verification.terminationStatus == 0 else {
            throw UpdateFailure.untrustedBundle(
                "the installed app has an invalid code signature; use the official installer."
            )
        }

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", "--verbose=4", applicationURL.path]
        )
        guard result.terminationStatus == 0 else {
            throw UpdateFailure.untrustedBundle(
                "the installed app signature could not be inspected; use the official installer."
            )
        }
        if let teamIdentifier = Self.teamIdentifier(from: result.output) {
            return teamIdentifier
        }
        guard result.output.contains("Signature=adhoc") else {
            throw UpdateFailure.untrustedBundle(
                "the installed app is neither Developer ID signed nor ad-hoc signed."
            )
        }
        return nil
    }

    private static func teamIdentifier(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("TeamIdentifier=") else { continue }
            let identifier = String(value.dropFirst("TeamIdentifier=".count))
            guard !identifier.isEmpty, identifier != "not set" else { return nil }
            return identifier
        }
        return nil
    }

    private struct BundleInfo {
        let bundleIdentifier: String?
        let shortVersion: String?
        let executable: String?
    }

    private static func readInfoPlist(applicationURL: URL) throws -> BundleInfo {
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        do {
            let data = try Data(contentsOf: infoURL)
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any] else {
                throw UpdateFailure.invalidBundle("Info.plist is not a dictionary.")
            }
            return BundleInfo(
                bundleIdentifier: dictionary["CFBundleIdentifier"] as? String,
                shortVersion: dictionary["CFBundleShortVersionString"] as? String,
                executable: dictionary["CFBundleExecutable"] as? String
            )
        } catch let failure as UpdateFailure {
            throw failure
        } catch {
            throw UpdateFailure.invalidBundle("Info.plist could not be read: \(error.localizedDescription)")
        }
    }
}

@MainActor
protocol UpdateApplicationControlling: AnyObject {
    func relaunch(applicationAt url: URL) async throws
    func terminateCurrentApplication()
}

@MainActor
final class SystemUpdateApplicationController: UpdateApplicationControlling {
    private let runner: any UpdateCommandRunning

    init(runner: any UpdateCommandRunning = SystemUpdateCommandRunner()) {
        self.runner = runner
    }

    func relaunch(applicationAt url: URL) async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-n", url.path]
        )
        guard result.terminationStatus == 0 else {
            throw UpdateFailure.installationFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    func terminateCurrentApplication() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Manager

@Observable
@MainActor
final class UpdateManager {
    static let defaultReleaseAPIURL = URL(
        string: "https://api.github.com/repos/sozua-ciandt/kill-the-bill/releases/latest"
    )!
    static let releaseAssetName = "KillTheBill.app.zip"
    static let defaultAutomaticCheckInterval: TimeInterval = 24 * 60 * 60
    static let automaticCheckTimestampKey = "updates.lastAutomaticCheckAt"

    private(set) var state: UpdateState = .idle
    private(set) var progress: Double?
    private(set) var availableRelease: UpdateRelease?
    private(set) var stagedUpdate: StagedUpdate?
    private(set) var errorMessage: String?
    private(set) var automaticChecksEnabled = false

    @ObservationIgnored private let httpClient: any UpdateHTTPClient
    @ObservationIgnored private let archiveExtractor: any UpdateArchiveExtracting
    @ObservationIgnored private let bundleValidator: any UpdateBundleValidating
    @ObservationIgnored private let applicationController: any UpdateApplicationControlling
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let releaseAPIURL: URL
    @ObservationIgnored private let currentVersion: SemanticVersion?
    @ObservationIgnored private let currentVersionString: String
    @ObservationIgnored private let currentApplicationURL: URL
    @ObservationIgnored private let expectedBundleIdentifier: String
    @ObservationIgnored private let stagingRoot: URL
    @ObservationIgnored private let automaticCheckInterval: TimeInterval
    @ObservationIgnored private let automaticCheckDefaults: UserDefaults
    @ObservationIgnored private let now: @MainActor @Sendable () -> Date
    @ObservationIgnored private var automaticCheckTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    init(
        httpClient: any UpdateHTTPClient = URLSessionUpdateHTTPClient(),
        archiveExtractor: (any UpdateArchiveExtracting)? = nil,
        bundleValidator: (any UpdateBundleValidating)? = nil,
        applicationController: (any UpdateApplicationControlling)? = nil,
        fileManager: FileManager = .default,
        releaseAPIURL: URL = UpdateManager.defaultReleaseAPIURL,
        currentVersionString: String = AppVersion.current.shortVersion,
        currentApplicationURL: URL = Bundle.main.bundleURL,
        expectedBundleIdentifier: String = Bundle.main.bundleIdentifier
            ?? "dev.sozua-ciandt.kill-the-bill",
        stagingRoot: URL? = nil,
        automaticCheckInterval: TimeInterval = UpdateManager.defaultAutomaticCheckInterval,
        automaticCheckDefaults: UserDefaults = .standard,
        now: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        let commandRunner = SystemUpdateCommandRunner()
        self.httpClient = httpClient
        self.archiveExtractor = archiveExtractor
            ?? DittoUpdateArchiveExtractor(runner: commandRunner)
        self.bundleValidator = bundleValidator
            ?? DeveloperIDUpdateBundleValidator(runner: commandRunner, fileManager: fileManager)
        self.applicationController = applicationController
            ?? SystemUpdateApplicationController(runner: commandRunner)
        self.fileManager = fileManager
        self.releaseAPIURL = releaseAPIURL
        self.currentVersionString = currentVersionString
        currentVersion = SemanticVersion(currentVersionString)
        self.currentApplicationURL = currentApplicationURL.standardizedFileURL
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.automaticCheckInterval = max(automaticCheckInterval, 1)
        self.automaticCheckDefaults = automaticCheckDefaults
        self.now = now

        if let stagingRoot {
            self.stagingRoot = stagingRoot.standardizedFileURL
        } else {
            let caches = (try? fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            self.stagingRoot = caches
                .appendingPathComponent(expectedBundleIdentifier, isDirectory: true)
                .appendingPathComponent("Updates", isDirectory: true)
        }
    }

    /// Starts or updates the background schedule. Background work only checks;
    /// downloading and installation always require an explicit user action.
    func start(automaticChecksEnabled: Bool) {
        setAutomaticChecksEnabled(automaticChecksEnabled)
    }

    func stop() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
        operationTask?.cancel()
        operationTask = nil
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        automaticChecksEnabled = enabled
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
        guard enabled else { return }

        enqueueAutomaticCheckIfDue()

        let interval = automaticCheckInterval
        automaticCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.enqueueAutomaticCheckIfDue()
            }
        }
    }

    func checkNow() {
        guard operationTask == nil else { return }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.checkNowAndWait()
            self.operationTask = nil
        }
    }

    /// Downloads, validates, and installs the available update in response to
    /// one explicit action. If the current bundle is not writable, it stops at
    /// `.ready` and exposes the staged archive for the external installer.
    func installAvailableUpdate() {
        guard operationTask == nil else { return }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.installAvailableUpdateAndWait()
            self.operationTask = nil
        }
    }

    // Internal async variants keep unit and integration tests deterministic.
    func checkNowAndWait() async {
        guard let currentVersion else {
            setFailure(.invalidCurrentVersion(currentVersionString))
            return
        }

        state = .checking
        progress = nil
        errorMessage = nil

        do {
            guard let release = try await fetchLatestEligibleRelease() else {
                availableRelease = nil
                state = .upToDate
                return
            }
            if release.version > currentVersion {
                availableRelease = release
                stagedUpdate = nil
                state = .available
            } else {
                availableRelease = nil
                stagedUpdate = nil
                state = .upToDate
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            setFailure(Self.failure(from: error))
        }
    }

    func installAvailableUpdateAndWait() async {
        do {
            let staged: StagedUpdate
            if let existing = stagedUpdate {
                staged = existing
            } else {
                guard let release = availableRelease else {
                    throw UpdateFailure.invalidRelease("no update has been selected")
                }
                staged = try await downloadAndStage(release)
                stagedUpdate = staged
            }

            switch staged.installationCapability {
            case .inPlace:
                try await installInPlace(staged)
            case .requiresExternalInstaller(let reason):
                state = .ready
                progress = 1
                errorMessage = reason
            }
        } catch is CancellationError {
            state = availableRelease == nil ? .idle : .available
        } catch {
            setFailure(Self.failure(from: error))
        }
    }

    private func enqueueAutomaticCheckIfDue() {
        guard automaticChecksEnabled,
              operationTask == nil,
              isAutomaticCheckDue else { return }
        switch state {
        case .downloading, .ready, .installing, .available:
            return
        case .idle, .checking, .upToDate, .error:
            break
        }

        // Persist before the request starts so a crash or network failure does
        // not turn every relaunch into another GitHub API request.
        automaticCheckDefaults.set(
            now().timeIntervalSince1970,
            forKey: Self.automaticCheckTimestampKey
        )
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.checkNowAndWait()
            self.operationTask = nil
        }
    }

    private var isAutomaticCheckDue: Bool {
        guard let lastAttempt = automaticCheckDefaults.object(
            forKey: Self.automaticCheckTimestampKey
        ) as? NSNumber else {
            return true
        }
        let elapsed = now().timeIntervalSince1970 - lastAttempt.doubleValue
        // A clock correction into the past should not suppress checks forever.
        return elapsed < 0 || elapsed >= automaticCheckInterval
    }

    private func fetchLatestEligibleRelease() async throws -> UpdateRelease? {
        var request = URLRequest(
            url: releaseAPIURL,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("KillTheBill/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdateFailure.network(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateFailure.invalidServerResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateFailure.httpStatus(httpResponse.statusCode)
        }

        let payload: GitHubReleasePayload
        do {
            payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        } catch {
            throw UpdateFailure.invalidRelease(error.localizedDescription)
        }
        guard !payload.draft, !payload.prerelease else { return nil }
        guard let version = SemanticVersion(payload.tagName) else {
            throw UpdateFailure.invalidRelease("tag \(payload.tagName) is not valid semantic versioning")
        }
        guard let asset = payload.assets.first(where: { $0.name == Self.releaseAssetName }) else {
            throw UpdateFailure.missingReleaseAsset(Self.releaseAssetName)
        }
        guard asset.size > 0 else {
            throw UpdateFailure.invalidRelease("the app archive is empty")
        }
        guard asset.browserDownloadURL.scheme == "https",
              asset.browserDownloadURL.host?.lowercased() == "github.com",
              asset.browserDownloadURL.path.hasPrefix(
                "/sozua-ciandt/kill-the-bill/releases/download/"
              ) else {
            throw UpdateFailure.invalidRelease("the app archive URL is outside the expected repository")
        }

        return UpdateRelease(
            tagName: payload.tagName,
            version: version,
            name: payload.name?.isEmpty == false ? payload.name! : payload.tagName,
            notes: payload.body ?? "",
            pageURL: payload.htmlURL,
            downloadURL: asset.browserDownloadURL,
            assetSize: asset.size,
            assetDigest: asset.digest
        )
    }

    private func downloadAndStage(_ release: UpdateRelease) async throws -> StagedUpdate {
        state = .downloading
        progress = nil // URLSession data(for:) is intentionally indeterminate.
        errorMessage = nil

        var request = URLRequest(
            url: release.downloadURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 120
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("KillTheBill/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdateFailure.network(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateFailure.invalidServerResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateFailure.httpStatus(httpResponse.statusCode)
        }
        guard Int64(data.count) == release.assetSize else {
            throw UpdateFailure.downloadSizeMismatch(
                expected: release.assetSize,
                actual: Int64(data.count)
            )
        }
        if let expectedDigest = release.assetDigest,
           expectedDigest.lowercased().hasPrefix("sha256:") {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let expected = String(expectedDigest.dropFirst("sha256:".count)).lowercased()
            guard actual == expected else { throw UpdateFailure.downloadDigestMismatch }
        }

        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let workingDirectory = stagingRoot.appendingPathComponent(
            "\(release.version.description)-\(UUID().uuidString)",
            isDirectory: true
        )
        guard Self.isDescendant(workingDirectory, of: stagingRoot) else {
            throw UpdateFailure.extractionFailed("unsafe staging directory")
        }

        do {
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: false)
            let archiveURL = workingDirectory.appendingPathComponent(Self.releaseAssetName)
            try data.write(to: archiveURL, options: [.atomic])
            let extractionDirectory = workingDirectory.appendingPathComponent("Expanded", isDirectory: true)
            try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: false)
            try await archiveExtractor.extract(archive: archiveURL, into: extractionDirectory)

            let topLevelItems = try fileManager.contentsOfDirectory(
                at: extractionDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            let applicationURL = extractionDirectory.appendingPathComponent(
                "KillTheBill.app",
                isDirectory: true
            )
            guard topLevelItems.count == 1,
                  topLevelItems[0].standardizedFileURL == applicationURL.standardizedFileURL else {
                throw UpdateFailure.invalidBundle("the archive must contain only KillTheBill.app.")
            }

            let validated = try await bundleValidator.validate(
                applicationURL: applicationURL,
                for: release,
                currentApplicationURL: currentApplicationURL,
                expectedBundleIdentifier: expectedBundleIdentifier
            )
            progress = 1

            let capability: StagedUpdate.InstallationCapability
            if canReplaceCurrentApplication() {
                capability = .inPlace
            } else {
                capability = .requiresExternalInstaller(
                    reason: "The update is ready, but \(currentApplicationURL.path) is not writable. "
                        + "Run the official installer to authorize replacing it."
                )
            }
            state = .ready
            return StagedUpdate(
                release: release,
                applicationURL: validated.applicationURL,
                archiveURL: archiveURL,
                workingDirectory: workingDirectory,
                teamIdentifier: validated.teamIdentifier,
                installationCapability: capability
            )
        } catch {
            try? safelyRemoveItem(at: workingDirectory)
            throw error
        }
    }

    private func installInPlace(_ staged: StagedUpdate) async throws {
        guard canReplaceCurrentApplication() else {
            throw UpdateFailure.installationRequiresExternalInstaller(
                "The current app location requires authorization. Run the official installer."
            )
        }
        guard currentApplicationURL.pathExtension == "app",
              currentApplicationURL.lastPathComponent == "KillTheBill.app" else {
            throw UpdateFailure.installationFailed("refusing to replace an unexpected application path")
        }

        state = .installing
        progress = nil
        errorMessage = nil

        let parent = currentApplicationURL.deletingLastPathComponent()
        let transactionID = UUID().uuidString
        let newURL = parent.appendingPathComponent(".KillTheBill.update-new-\(transactionID).app")
        let backupURL = parent.appendingPathComponent(".KillTheBill.update-backup-\(transactionID).app")
        guard Self.isDirectChild(newURL, of: parent), Self.isDirectChild(backupURL, of: parent) else {
            throw UpdateFailure.installationFailed("unsafe replacement paths")
        }

        var movedCurrentToBackup = false
        do {
            try fileManager.copyItem(at: staged.applicationURL, to: newURL)
            _ = try await bundleValidator.validate(
                applicationURL: newURL,
                for: staged.release,
                currentApplicationURL: currentApplicationURL,
                expectedBundleIdentifier: expectedBundleIdentifier
            )

            try fileManager.moveItem(at: currentApplicationURL, to: backupURL)
            movedCurrentToBackup = true
            do {
                try fileManager.moveItem(at: newURL, to: currentApplicationURL)
            } catch {
                do {
                    try fileManager.moveItem(at: backupURL, to: currentApplicationURL)
                    movedCurrentToBackup = false
                } catch {
                    // The outer rollback gets another chance and deliberately
                    // leaves the backup intact if restoration remains blocked.
                }
                throw error
            }

            do {
                _ = try await bundleValidator.validate(
                    applicationURL: currentApplicationURL,
                    for: staged.release,
                    currentApplicationURL: backupURL,
                    expectedBundleIdentifier: expectedBundleIdentifier
                )
                try await applicationController.relaunch(applicationAt: currentApplicationURL)
            } catch {
                try? fileManager.removeItem(at: currentApplicationURL)
                do {
                    try fileManager.moveItem(at: backupURL, to: currentApplicationURL)
                    movedCurrentToBackup = false
                } catch {
                    // Preserve the backup and retry from the outer rollback.
                }
                throw error
            }

            try? fileManager.removeItem(at: backupURL)
            movedCurrentToBackup = false
            try? safelyRemoveItem(at: staged.workingDirectory)
            stagedUpdate = nil
            state = .idle
            applicationController.terminateCurrentApplication()
        } catch {
            if fileManager.fileExists(atPath: newURL.path) {
                try? fileManager.removeItem(at: newURL)
            }
            if movedCurrentToBackup,
               !fileManager.fileExists(atPath: currentApplicationURL.path) {
                try? fileManager.moveItem(at: backupURL, to: currentApplicationURL)
            }
            throw UpdateFailure.installationFailed(error.localizedDescription)
        }
    }

    private func canReplaceCurrentApplication() -> Bool {
        let parent = currentApplicationURL.deletingLastPathComponent()
        guard currentApplicationURL.pathExtension == "app",
              currentApplicationURL.lastPathComponent == "KillTheBill.app",
              fileManager.fileExists(atPath: currentApplicationURL.path),
              fileManager.isWritableFile(atPath: parent.path) else {
            return false
        }
        let values = try? currentApplicationURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private func safelyRemoveItem(at url: URL) throws {
        guard Self.isDescendant(url, of: stagingRoot) else {
            throw UpdateFailure.installationFailed("refusing to remove an unsafe path")
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func setFailure(_ failure: UpdateFailure) {
        progress = nil
        errorMessage = failure.localizedDescription
        state = .error
    }

    private static func failure(from error: Error) -> UpdateFailure {
        if let failure = error as? UpdateFailure { return failure }
        return .network(error.localizedDescription)
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }

    private static func isDirectChild(_ child: URL, of parent: URL) -> Bool {
        child.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL
    }
}

private struct GitHubReleasePayload: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int64
        let digest: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case digest
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case htmlURL = "html_url"
        case assets
    }
}

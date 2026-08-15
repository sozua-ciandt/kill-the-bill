import AppKit
import Foundation

enum AppInstanceGuard {
    struct RunningInstance: Equatable, Sendable {
        let processIdentifier: pid_t
        let bundleURL: URL?
        let launchDate: Date?
    }

    /// When legacy installs exist in both /Applications and ~/Applications,
    /// launchd can briefly start both. Every instance computes the same winner:
    /// prefer the system Applications copy, then the user Applications copy,
    /// then the newest process. Preferring the newest at the same path is
    /// important during an updater relaunch: the replacement must survive long
    /// enough for the previous process to terminate. Losing instances terminate
    /// themselves.
    @MainActor
    static func shouldKeepCurrentInstance(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return true }

        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        let instances = applications.map {
            RunningInstance(
                processIdentifier: $0.processIdentifier,
                bundleURL: $0.bundleURL,
                launchDate: $0.launchDate
            )
        }
        return shouldKeep(
            currentProcessIdentifier: currentProcessIdentifier,
            among: instances
        )
    }

    /// Pure selection boundary used by the AppKit adapter above and unit tests.
    static func shouldKeep(
        currentProcessIdentifier: pid_t,
        among instances: [RunningInstance],
        userApplicationsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/KillTheBill.app")
    ) -> Bool {
        guard instances.count > 1 else { return true }

        let sorted = instances.sorted { left, right in
            let leftRank = locationRank(
                left.bundleURL,
                userApplicationsURL: userApplicationsURL
            )
            let rightRank = locationRank(
                right.bundleURL,
                userApplicationsURL: userApplicationsURL
            )
            if leftRank != rightRank { return leftRank < rightRank }

            let leftDate = left.launchDate ?? .distantPast
            let rightDate = right.launchDate ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.processIdentifier > right.processIdentifier
        }

        return sorted.first?.processIdentifier == currentProcessIdentifier
    }

    private static func locationRank(
        _ bundleURL: URL?,
        userApplicationsURL: URL
    ) -> Int {
        guard let path = bundleURL?.standardizedFileURL.path else { return 3 }
        if path == "/Applications/KillTheBill.app" { return 0 }

        let userApplications = userApplicationsURL.standardizedFileURL.path
        if path == userApplications { return 1 }
        return 2
    }
}

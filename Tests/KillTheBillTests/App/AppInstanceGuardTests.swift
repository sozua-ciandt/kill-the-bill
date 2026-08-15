import Foundation
import XCTest
@testable import KillTheBill

final class AppInstanceGuardTests: XCTestCase {
    private let systemApp = URL(fileURLWithPath: "/Applications/KillTheBill.app")
    private let userApp = URL(fileURLWithPath: "/Users/test/Applications/KillTheBill.app")

    func testSameLocationKeepsNewestInstanceAndUsesNewestPIDAsTieBreaker() {
        let older = instance(pid: 100, url: systemApp, launchedAt: 100)
        let newer = instance(pid: 90, url: systemApp, launchedAt: 200)

        XCTAssertTrue(shouldKeep(pid: newer.processIdentifier, among: [older, newer]))
        XCTAssertFalse(shouldKeep(pid: older.processIdentifier, among: [older, newer]))

        let lowerPID = instance(pid: 200, url: systemApp, launchedAt: 300)
        let higherPID = instance(pid: 201, url: systemApp, launchedAt: 300)

        XCTAssertTrue(shouldKeep(pid: higherPID.processIdentifier, among: [lowerPID, higherPID]))
        XCTAssertFalse(shouldKeep(pid: lowerPID.processIdentifier, among: [lowerPID, higherPID]))
    }

    func testSystemApplicationsWinsOverNewerUserApplicationsInstance() {
        let olderSystem = instance(pid: 100, url: systemApp, launchedAt: 100)
        let newerUser = instance(pid: 200, url: userApp, launchedAt: 200)

        XCTAssertTrue(shouldKeep(pid: olderSystem.processIdentifier, among: [newerUser, olderSystem]))
        XCTAssertFalse(shouldKeep(pid: newerUser.processIdentifier, among: [newerUser, olderSystem]))
    }

    func testSingleInstanceAlwaysRemains() {
        let onlyInstance = instance(pid: 100, url: userApp, launchedAt: 100)

        XCTAssertTrue(shouldKeep(pid: onlyInstance.processIdentifier, among: [onlyInstance]))
    }

    private func instance(
        pid: pid_t,
        url: URL,
        launchedAt timestamp: TimeInterval
    ) -> AppInstanceGuard.RunningInstance {
        AppInstanceGuard.RunningInstance(
            processIdentifier: pid,
            bundleURL: url,
            launchDate: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func shouldKeep(
        pid: pid_t,
        among instances: [AppInstanceGuard.RunningInstance]
    ) -> Bool {
        AppInstanceGuard.shouldKeep(
            currentProcessIdentifier: pid,
            among: instances,
            userApplicationsURL: userApp
        )
    }
}

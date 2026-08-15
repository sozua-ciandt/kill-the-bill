import Foundation
import XCTest
@testable import KillTheBill

@MainActor
final class LaunchAtLoginManagerTests: XCTestCase {
    func testReconcileRegistersOnceWhenDesiredByDefault() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let manager = LaunchAtLoginManager(service: service)

        manager.reconcile(desiredEnabled: true)
        manager.reconcile(desiredEnabled: true)

        XCTAssertEqual(service.registrationCount, 1)
        XCTAssertEqual(manager.status, .enabled)
        XCTAssertTrue(manager.desiredEnabled)
        XCTAssertNil(manager.errorMessage)
    }

    func testExistingFalsePreferenceUnregistersAndRemainsDisabled() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let manager = LaunchAtLoginManager(service: service)

        manager.reconcile(desiredEnabled: false)
        manager.reconcile(desiredEnabled: false)

        XCTAssertEqual(service.unregistrationCount, 1)
        XCTAssertEqual(manager.status, .notRegistered)
        XCTAssertFalse(manager.desiredEnabled)
    }

    func testRequiresApprovalIsExposedWithoutRegistrationLoop() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let manager = LaunchAtLoginManager(service: service)

        manager.reconcile(desiredEnabled: true)
        manager.openSystemSettings()

        XCTAssertEqual(manager.status, .requiresApproval)
        XCTAssertEqual(service.registrationCount, 0)
        XCTAssertTrue(service.didOpenSettings)
    }

    func testRegistrationFailureIsVisible() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestLaunchAtLoginError.denied
        let manager = LaunchAtLoginManager(service: service)

        manager.setEnabled(true)

        XCTAssertEqual(manager.status, .error)
        XCTAssertEqual(manager.errorMessage, "Registration denied")
    }

    func testRefreshReflectsExternalSystemChange() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let manager = LaunchAtLoginManager(service: service)
        service.status = .requiresApproval

        manager.refreshStatus()

        XCTAssertEqual(manager.status, .requiresApproval)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registrationCount = 0
    private(set) var unregistrationCount = 0
    private(set) var didOpenSettings = false

    init(status: LaunchAtLoginServiceStatus) {
        self.status = status
    }

    func register() throws {
        registrationCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregistrationCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettings() {
        didOpenSettings = true
    }
}

private enum TestLaunchAtLoginError: LocalizedError {
    case denied

    var errorDescription: String? { "Registration denied" }
}

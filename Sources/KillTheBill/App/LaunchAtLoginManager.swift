import Foundation
import Observation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case error
}

enum LaunchAtLoginServiceStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginServiceStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginServiceStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@Observable
@MainActor
final class LaunchAtLoginManager {
    private(set) var status: LaunchAtLoginStatus = .notRegistered
    private(set) var errorMessage: String?
    private(set) var desiredEnabled = true

    @ObservationIgnored private let service: any LaunchAtLoginServicing

    init(service: (any LaunchAtLoginServicing)? = nil) {
        self.service = service ?? SystemLaunchAtLoginService()
        refreshStatus()
    }

    /// Reconciles the product preference with Service Management. Calls are
    /// idempotent: an enabled service is not re-registered and an absent one is
    /// not unregistered again.
    func reconcile(desiredEnabled: Bool) {
        self.desiredEnabled = desiredEnabled
        errorMessage = nil

        if desiredEnabled {
            switch service.status {
            case .enabled:
                status = .enabled
            case .requiresApproval:
                status = .requiresApproval
            case .notRegistered:
                do {
                    try service.register()
                    refreshStatus()
                } catch {
                    // `register()` may race a System Settings change. Prefer the
                    // resulting system state when it became valid meanwhile.
                    let resultingStatus = service.status
                    if resultingStatus == .enabled || resultingStatus == .requiresApproval {
                        refreshStatus()
                    } else {
                        setError(error)
                    }
                }
            case .notFound:
                setErrorMessage("macOS could not find the main application login item.")
            }
        } else {
            switch service.status {
            case .notRegistered:
                status = .notRegistered
            case .enabled, .requiresApproval:
                do {
                    try service.unregister()
                    refreshStatus()
                } catch {
                    if service.status == .notRegistered {
                        refreshStatus()
                    } else {
                        setError(error)
                    }
                }
            case .notFound:
                // A missing service is effectively disabled, but retain a clear
                // diagnostic rather than claiming registration succeeded.
                setErrorMessage("macOS could not find the main application login item.")
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        reconcile(desiredEnabled: enabled)
    }

    func refreshStatus() {
        errorMessage = nil
        switch service.status {
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notRegistered:
            status = .notRegistered
        case .notFound:
            setErrorMessage("macOS could not find the main application login item.")
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private func setError(_ error: Error) {
        setErrorMessage(error.localizedDescription)
    }

    private func setErrorMessage(_ message: String) {
        errorMessage = message
        status = .error
    }
}

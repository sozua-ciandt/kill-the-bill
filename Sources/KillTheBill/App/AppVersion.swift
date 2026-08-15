import Foundation

struct AppVersion: Equatable, Sendable {
    let shortVersion: String
    let build: String?

    var displayName: String { "v\(shortVersion)" }

    var detailedDisplayName: String {
        guard let build, !build.isEmpty else { return displayName }
        return "\(displayName) (\(build))"
    }

    static var current: AppVersion {
        from(bundle: .main)
    }

    static func from(bundle: Bundle) -> AppVersion {
        from(infoDictionary: bundle.infoDictionary)
    }

    static func from(infoDictionary: [String: Any]?) -> AppVersion {
        let shortVersion = infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
        let build = infoDictionary?["CFBundleVersion"] as? String
        return AppVersion(shortVersion: shortVersion, build: build)
    }
}

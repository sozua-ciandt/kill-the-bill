import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case english = "en"
    case portugueseBrazil = "pt-BR"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .portugueseBrazil:
            return Locale(identifier: "pt-BR")
        }
    }
}

enum FlowLimitPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case individual
    case tenant
    case effective

    var id: String { rawValue }
}

enum Harness: String, CaseIterable, Codable, Identifiable, Sendable {
    case claudeCode
    case codex
    case opencode

    var id: String { rawValue }
}

enum OverviewRankingPeriod: String, CaseIterable, Codable, Identifiable, Sendable {
    case monthly
    case daily

    var id: String { rawValue }
}

struct SettingsSnapshot: Equatable, Sendable {
    let autoUpdateEnabled: Bool
    let launchAtLogin: Bool
    let showEvents: Bool
    let flowEnabled: Bool
    let flowCacheTTL: TimeInterval
    let monthlyEventLimit: Int
    let monthlyCostLimit: Double
    let flowLimitPolicy: FlowLimitPolicy
    let trackedHarnesses: Set<Harness>
    let language: AppLanguage
    let overviewRanking: OverviewRankingPeriod
}

@Observable
@MainActor
final class AppSettings {
    static let defaultFlowCacheTTL: TimeInterval = 60
    static let flowCacheTTLRange: ClosedRange<TimeInterval> = 30...3_600

    private static let currentSchemaVersion = 1

    private enum Key {
        static let schemaVersion = "settingsSchemaVersion"
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let showEvents = "showEvents"
        static let flowEnabled = "flowEnabled"
        static let flowCacheTTL = "flowCacheTTL"
        static let monthlyEventLimit = "monthlyEventLimit"
        static let monthlyCostLimit = "monthlyCostLimit"
        static let flowLimitPolicy = "flowLimitPolicy"
        static let trackedHarnesses = "trackedHarnesses"
        static let language = "language"
        static let overviewRanking = "overviewRanking"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var autoUpdateEnabled: Bool {
        didSet { defaults.set(autoUpdateEnabled, forKey: Key.autoUpdateEnabled) }
    }

    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    var showEvents: Bool {
        didSet { defaults.set(showEvents, forKey: Key.showEvents) }
    }

    var flowEnabled: Bool {
        didSet { defaults.set(flowEnabled, forKey: Key.flowEnabled) }
    }

    private var storedFlowCacheTTL: TimeInterval

    var flowCacheTTL: TimeInterval {
        get { storedFlowCacheTTL }
        set {
            let clampedValue = Self.clampedFlowCacheTTL(newValue)
            storedFlowCacheTTL = clampedValue
            defaults.set(clampedValue, forKey: Key.flowCacheTTL)
        }
    }

    private var storedMonthlyEventLimit: Int

    var monthlyEventLimit: Int {
        get { storedMonthlyEventLimit }
        set {
            let clampedValue = max(newValue, 0)
            storedMonthlyEventLimit = clampedValue
            defaults.set(clampedValue, forKey: Key.monthlyEventLimit)
        }
    }

    private var storedMonthlyCostLimit: Double

    var monthlyCostLimit: Double {
        get { storedMonthlyCostLimit }
        set {
            let clampedValue = Self.clampedMonthlyCostLimit(newValue)
            storedMonthlyCostLimit = clampedValue
            defaults.set(clampedValue, forKey: Key.monthlyCostLimit)
        }
    }

    var flowLimitPolicy: FlowLimitPolicy {
        didSet { defaults.set(flowLimitPolicy.rawValue, forKey: Key.flowLimitPolicy) }
    }

    var trackedHarnesses: Set<Harness> {
        didSet {
            defaults.set(
                trackedHarnesses.map(\.rawValue).sorted(),
                forKey: Key.trackedHarnesses
            )
        }
    }

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    var overviewRanking: OverviewRankingPeriod {
        didSet { defaults.set(overviewRanking.rawValue, forKey: Key.overviewRanking) }
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            autoUpdateEnabled: autoUpdateEnabled,
            launchAtLogin: launchAtLogin,
            showEvents: showEvents,
            flowEnabled: flowEnabled,
            flowCacheTTL: flowCacheTTL,
            monthlyEventLimit: monthlyEventLimit,
            monthlyCostLimit: monthlyCostLimit,
            flowLimitPolicy: flowLimitPolicy,
            trackedHarnesses: trackedHarnesses,
            language: language,
            overviewRanking: overviewRanking
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        Self.migrateIfNeeded(defaults)
        defaults.register(defaults: Self.registeredDefaults)

        autoUpdateEnabled = defaults.bool(forKey: Key.autoUpdateEnabled)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        showEvents = defaults.bool(forKey: Key.showEvents)
        flowEnabled = defaults.bool(forKey: Key.flowEnabled)
        storedFlowCacheTTL = Self.clampedFlowCacheTTL(
            defaults.double(forKey: Key.flowCacheTTL)
        )
        storedMonthlyEventLimit = max(defaults.integer(forKey: Key.monthlyEventLimit), 0)
        storedMonthlyCostLimit = Self.clampedMonthlyCostLimit(
            defaults.double(forKey: Key.monthlyCostLimit)
        )
        flowLimitPolicy = FlowLimitPolicy(
            rawValue: defaults.string(forKey: Key.flowLimitPolicy) ?? ""
        ) ?? .automatic
        trackedHarnesses = Set(
            (defaults.stringArray(forKey: Key.trackedHarnesses) ?? [])
                .compactMap(Harness.init(rawValue:))
        )
        language = AppLanguage(
            rawValue: defaults.string(forKey: Key.language) ?? ""
        ) ?? .system
        overviewRanking = OverviewRankingPeriod(
            rawValue: defaults.string(forKey: Key.overviewRanking) ?? ""
        ) ?? .monthly
    }

    private static var registeredDefaults: [String: Any] {
        [
            Key.autoUpdateEnabled: true,
            Key.launchAtLogin: true,
            Key.showEvents: false,
            Key.flowEnabled: true,
            Key.flowCacheTTL: defaultFlowCacheTTL,
            Key.monthlyEventLimit: 6_000,
            Key.monthlyCostLimit: 0.0,
            Key.flowLimitPolicy: FlowLimitPolicy.automatic.rawValue,
            Key.trackedHarnesses: Harness.allCases.map(\.rawValue),
            Key.language: AppLanguage.system.rawValue,
            Key.overviewRanking: OverviewRankingPeriod.monthly.rawValue,
        ]
    }

    private static func migrateIfNeeded(_ defaults: UserDefaults) {
        let version = defaults.integer(forKey: Key.schemaVersion)
        guard version < currentSchemaVersion else { return }

        // Version 1 keeps the legacy AppStorage keys for launch-at-login,
        // display mode, and monthly limits, so existing choices carry over.
        // New settings are supplied through the registration domain and only
        // become persistent when the user changes them.
        defaults.set(currentSchemaVersion, forKey: Key.schemaVersion)
    }

    private static func clampedFlowCacheTTL(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultFlowCacheTTL }
        return min(max(value, flowCacheTTLRange.lowerBound), flowCacheTTLRange.upperBound)
    }

    private static func clampedMonthlyCostLimit(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }
}

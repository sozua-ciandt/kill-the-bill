import Foundation
import XCTest
@testable import KillTheBill

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testFreshInstallUsesProductDefaults() {
        let fixture = SettingsDefaultsFixture()
        let settings = AppSettings(defaults: fixture.defaults)

        XCTAssertTrue(settings.autoUpdateEnabled)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertFalse(settings.showEvents)
        XCTAssertTrue(settings.flowEnabled)
        XCTAssertEqual(settings.flowCacheTTL, 60)
        XCTAssertEqual(settings.monthlyEventLimit, 6_000)
        XCTAssertEqual(settings.monthlyCostLimit, 0)
        XCTAssertEqual(settings.flowLimitPolicy, .automatic)
        XCTAssertEqual(settings.trackedHarnesses, Set(Harness.allCases))
        XCTAssertEqual(settings.language, .system)
    }

    @MainActor
    func testLegacyAppStorageValuesArePreserved() {
        let fixture = SettingsDefaultsFixture()
        fixture.defaults.set(false, forKey: "launchAtLogin")
        fixture.defaults.set(true, forKey: "showEvents")
        fixture.defaults.set(9_000, forKey: "monthlyEventLimit")
        fixture.defaults.set(250.0, forKey: "monthlyCostLimit")

        let settings = AppSettings(defaults: fixture.defaults)

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.showEvents)
        XCTAssertEqual(settings.monthlyEventLimit, 9_000)
        XCTAssertEqual(settings.monthlyCostLimit, 250)
    }

    @MainActor
    func testMutationsPersistAndSnapshotAllValues() {
        let fixture = SettingsDefaultsFixture()
        let settings = AppSettings(defaults: fixture.defaults)
        settings.autoUpdateEnabled = false
        settings.launchAtLogin = false
        settings.showEvents = true
        settings.flowEnabled = false
        settings.flowCacheTTL = 300
        settings.monthlyEventLimit = 12_000
        settings.monthlyCostLimit = 500
        settings.flowLimitPolicy = .individual
        settings.trackedHarnesses = [.codex]
        settings.language = .portugueseBrazil

        let restored = AppSettings(defaults: fixture.defaults)

        XCTAssertEqual(restored.snapshot, settings.snapshot)
        XCTAssertEqual(restored.trackedHarnesses, [.codex])
        XCTAssertEqual(restored.language, .portugueseBrazil)
    }

    @MainActor
    func testNumericSettingsAreClamped() {
        let fixture = SettingsDefaultsFixture()
        let settings = AppSettings(defaults: fixture.defaults)

        settings.flowCacheTTL = 1
        settings.monthlyEventLimit = -1
        settings.monthlyCostLimit = -1

        XCTAssertEqual(settings.flowCacheTTL, AppSettings.flowCacheTTLRange.lowerBound)
        XCTAssertEqual(settings.monthlyEventLimit, 0)
        XCTAssertEqual(settings.monthlyCostLimit, 0)

        settings.flowCacheTTL = 100_000
        XCTAssertEqual(settings.flowCacheTTL, AppSettings.flowCacheTTLRange.upperBound)
    }
}

private final class SettingsDefaultsFixture {
    let defaults: UserDefaults
    private let suiteName: String

    init() {
        suiteName = "AppSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

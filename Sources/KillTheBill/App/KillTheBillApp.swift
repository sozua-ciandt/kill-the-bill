import AppKit
import SwiftUI

@main
struct KillTheBillApp: App {
    @State private var settings: AppSettings
    @State private var store: UsageStore
    @State private var updater: UpdateManager
    @State private var launchAtLoginManager: LaunchAtLoginManager
    @State private var settingsWindowController: SettingsWindowController
    @State private var didStart = false

    init() {
        let settings = AppSettings()
        let store = UsageStore(settings: settings)
        let updater = UpdateManager()
        let launchAtLoginManager = LaunchAtLoginManager()
        let settingsWindowController = SettingsWindowController(
            settings: settings,
            store: store,
            updater: updater,
            launchAtLoginManager: launchAtLoginManager
        )

        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        _updater = State(initialValue: updater)
        _launchAtLoginManager = State(initialValue: launchAtLoginManager)
        _settingsWindowController = State(initialValue: settingsWindowController)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                store: store,
                settings: settings,
                updater: updater,
                onOpenSettings: settingsWindowController.show
            )
        } label: {
            menuBarLabel
                .onAppear(perform: startServicesIfNeeded)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "brain.fill")
                .symbolRenderingMode(.hierarchical)
            Text(settings.showEvents ? eventsLabel : costLabel)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(settings.showEvents ? eventsColor : costColor)
        }
    }

    private var l10n: AppLocalizer { AppLocalizer(language: settings.language) }

    private var costLabel: String {
        l10n.format("menubar.cost", l10n.currency(store.usage.monthlyCostUSD))
    }

    private var costColor: Color {
        if case .flow(let percentage, let limit, _) = store.usage.monthlyCostSource,
           limit > 0 {
            return thresholdColor(percentage / 100)
        }
        if settings.monthlyCostLimit > 0 {
            return thresholdColor(store.usage.monthlyCostUSD / settings.monthlyCostLimit)
        }
        return .green
    }

    private var eventsLabel: String {
        l10n.plural(
            singular: "menubar.event.one",
            plural: "menubar.event.many",
            count: store.usage.turnCount
        )
    }

    private var eventsColor: Color {
        let limit = max(settings.monthlyEventLimit, 1)
        return thresholdColor(Double(store.usage.monthlyTurnCount) / Double(limit))
    }

    private func thresholdColor(_ fraction: Double) -> Color {
        if fraction < 0.8 { return .green }
        if fraction < 0.95 { return .orange }
        return .red
    }

    private func startServicesIfNeeded() {
        guard !didStart else { return }
        didStart = true

        guard AppInstanceGuard.shouldKeepCurrentInstance() else {
            NSApplication.shared.terminate(nil)
            return
        }

        store.start()
        launchAtLoginManager.reconcile(desiredEnabled: settings.launchAtLogin)
        updater.start(automaticChecksEnabled: settings.autoUpdateEnabled)
    }
}

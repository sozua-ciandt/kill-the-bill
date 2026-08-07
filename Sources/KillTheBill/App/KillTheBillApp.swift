import SwiftUI
import ServiceManagement

@main
struct KillTheBillApp: App {
    @State private var store = UsageStore()
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showEvents") private var showEvents = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store, launchAtLogin: $launchAtLogin, showEvents: $showEvents)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
        .onChange(of: launchAtLogin) { _, enabled in
            setLaunchAtLogin(enabled)
        }
    }

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "brain.fill")
                .symbolRenderingMode(.hierarchical)
            Text(showEvents ? eventsLabel : costLabel)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(showEvents ? eventsColor : costColor)
        }
        .onAppear { store.start() }
    }

    private var costLabel: String {
        let cost = store.usage.monthlyCostUSD
        if cost == 0 { return "$0/mo" }
        if cost < 1 { return String(format: "$%.2f/mo", cost) }
        return String(format: "$%.1f/mo", cost)
    }

    private var costColor: Color {
        let cost = store.usage.monthlyCostUSD
        if cost < 50 { return .green }
        if cost < 150 { return .orange }
        return .red
    }

    private var eventsLabel: String {
        let n = store.usage.turnCount
        if n >= 1000 { return String(format: "%.1fk events", Double(n) / 1000) }
        return "\(n) events"
    }

    private var eventsColor: Color {
        let n = store.usage.turnCount
        if n < 500 { return .green }
        if n < 1000 { return .orange }
        return .red
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {}
    }
}

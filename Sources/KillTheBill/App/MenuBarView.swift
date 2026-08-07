import SwiftUI

struct MenuBarView: View {
    let store: UsageStore
    @Binding var launchAtLogin: Bool
    @Binding var showEvents: Bool
    @AppStorage("monthlyEventLimit") private var monthlyEventLimit: Int = 6000
    @AppStorage("monthlyCostLimit") private var monthlyCostLimit: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if showEvents {
                monthlyEventsSection
            } else {
                monthlyCostSection
            }
            Divider()
            tokenSection
            if store.usage.hasUnpricedUsage {
                unpricedWarning
            }
            Divider()
            modelSection
            Divider()
            workspaceSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        .id(showEvents)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(showEvents ? "Today's Events" : "This Month's Cost")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showEvents {
                    Text("\(store.usage.turnCount)")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(eventsColor)
                } else {
                    Text(formatCurrency(store.usage.monthlyCostUSD))
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(costColor)
                    Text("today: " + formatCurrency(store.usage.totalCostUSD))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(store.usage.sessionCount) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(store.usage.turnCount) events")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Vertical toggle: Cost ↕ Events
                HStack(spacing: 0) {
                    Button(action: { showEvents = false }) {
                        Image(systemName: "dollarsign")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 28, height: 18)
                            .background(showEvents ? Color.clear : Color.accentColor)
                            .foregroundStyle(showEvents ? Color.secondary : Color.white)
                    }
                    .buttonStyle(.plain)

                    Button(action: { showEvents = true }) {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 28, height: 18)
                            .background(showEvents ? Color.accentColor : Color.clear)
                            .foregroundStyle(showEvents ? Color.white : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            }
        }
    }

    // MARK: - Tokens

    private var unpricedWarning: some View {
        Text("Subscriptions excluded; add rules in \(providerDirectoryLabel) for custom events.")
            .font(.caption2)
            .foregroundStyle(Color.secondary.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var providerDirectoryLabel: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = store.providerDirectory.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTokens(store.usage.totalTokens) + " total")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 16) {
                tokenPill("Input", value: store.usage.inputTokens,
                          icon: "arrow.down.circle.fill", color: .blue)
                tokenPill("Output", value: store.usage.outputTokens,
                          icon: "arrow.up.circle.fill", color: .green)
            }

            HStack(spacing: 16) {
                tokenPill("Cache R", value: store.usage.cacheReadTokens,
                          icon: "square.and.arrow.up.fill", color: .purple)
                tokenPill("Cache W", value: store.usage.cacheWriteTokens,
                          icon: "square.and.arrow.down.fill", color: .orange)
            }
        }
    }

    private func tokenPill(_ label: String, value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatTokens(value))
                .font(.system(.caption, design: .monospaced, weight: .medium))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Monthly Events

    private var monthlyEventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This Month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 2) {
                    Text("limit:")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("6000", value: $monthlyEventLimit, format: .number)
                        .font(.system(.caption2, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            let used = store.usage.monthlyTurnCount
            let limit = max(monthlyEventLimit, 1)
            let progress = min(Double(used) / Double(limit), 1.0)

            ProgressView(value: progress)
                .tint(progressColor(progress))
                .scaleEffect(x: 1, y: 1.5)

            HStack {
                Text("\(used) events used")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(max(limit - used, 0)) remaining")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(progressColor(progress))
            }
        }
    }

    // MARK: - Monthly Cost

    private var monthlyCostSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This Month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 2) {
                    Text("limit $:")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("0", value: $monthlyCostLimit, format: .number)
                        .font(.system(.caption2, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            if let p = costLimitProgress {
                ProgressView(value: p.fraction)
                    .tint(progressColor(p.fraction))
                    .scaleEffect(x: 1, y: 1.5)

                HStack {
                    Text(formatCurrency(p.used) + " used")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatCurrency(p.remaining) + " remaining")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(progressColor(p.fraction))
                }
            }
        }
    }

    private struct CostProgress {
        let used: Double
        let remaining: Double
        let fraction: Double
    }

    private var costLimitProgress: CostProgress? {
        guard monthlyCostLimit > 0 else { return nil }
        let used = store.usage.monthlyCostUSD
        let limit = max(monthlyCostLimit, 0.01)
        let fraction = min(used / limit, 1.0)
        return CostProgress(used: used, remaining: max(limit - used, 0), fraction: fraction)
    }

    private func progressColor(_ progress: Double) -> Color {
        if progress < 0.6 { return .green }
        if progress < 0.85 { return .orange }
        return .red
    }

    // MARK: - Models

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.usage.perModel.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(store.usage.perModel) { m in
                    HStack {
                        Text(m.id)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if showEvents {
                            eventCountLabel(m.turnCount)
                        } else {
                            costDailyMonthlyLabel(daily: m.costUSD, monthly: m.monthlyCostUSD)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Workspaces

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Projects")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.usage.perWorkspace.isEmpty {
                Text("No sessions today")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(store.usage.perWorkspace) { ws in
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(ws.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if showEvents {
                            eventCountLabel(ws.turnCount)
                        } else {
                            costDailyMonthlyLabel(daily: ws.costUSD, monthly: ws.monthlyCostUSD)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .padding(.leading, 2)

            HStack {
                if store.lastRefreshed != .distantPast {
                    Text("Updated \(store.lastRefreshed, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Loading…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let sources = store.sources {
                    Text(sources.sourceCount == 1 ? "1 source" : "\(sources.sourceCount) sources")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }

                Button(action: { store.refresh() }) {
                    if store.isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .disabled(store.isLoading)

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "xmark.circle").font(.caption)
                }
                .buttonStyle(.plain)
                .help("Quit")
            }
        }
    }

    // MARK: - Formatting

    private var costColor: Color {
        let c = store.usage.monthlyCostUSD
        if c < 50 { return .green }
        if c < 150 { return .orange }
        return .red
    }

    private var eventsColor: Color {
        let n = store.usage.turnCount
        if n < 500 { return .green }
        if n < 1000 { return .orange }
        return .red
    }

    private func formatCurrency(_ value: Double) -> String { String(format: "$%.2f", value) }

    private func eventCountLabel(_ count: Int) -> some View {
        HStack(spacing: 2) {
            Text("\(count)")
                .foregroundStyle(.primary)
            Text("ev.")
                .foregroundStyle(Color.secondary.opacity(0.9))
        }
        .font(.system(.caption, design: .monospaced, weight: .medium))
    }

    private func costDailyMonthlyLabel(daily: Double, monthly: Double) -> some View {
        HStack(spacing: 2) {
            Text(formatCurrency(daily))
                .foregroundStyle(.primary)
            Text("/")
                .foregroundStyle(Color.secondary.opacity(0.5))
            Text(formatCurrency(monthly))
                .foregroundStyle(.secondary)
        }
        .font(.system(.caption2, design: .monospaced, weight: .medium))
        .accessibilityLabel("\(formatCurrency(daily)) today, \(formatCurrency(monthly)) this month")
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

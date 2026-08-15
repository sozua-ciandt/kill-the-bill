import AppKit
import SwiftUI

private enum MenuRoute: Equatable {
    case overview
    case sessions
    case sessionDetail(UsageSessionID)
}

struct MenuBarView: View {
    let store: UsageStore
    @Bindable var settings: AppSettings
    @Bindable var updater: UpdateManager
    let onOpenSettings: @MainActor () -> Void

    @State private var route: MenuRoute = .overview
    @State private var sessionPeriod: SessionPeriodPreset = .month
    @State private var sessionCustomStart = Calendar.current.date(
        byAdding: .day,
        value: -7,
        to: Date()
    ) ?? Date()
    @State private var sessionCustomEnd = Date()

    var body: some View {
        Group {
            switch route {
            case .overview:
                OverviewView(
                    store: store,
                    settings: settings,
                    updater: updater,
                    onShowSessions: { route = .sessions },
                    onOpenSettings: onOpenSettings
                )

            case .sessions:
                SessionListView(
                    store: store,
                    settings: settings,
                    period: $sessionPeriod,
                    customStart: $sessionCustomStart,
                    customEnd: $sessionCustomEnd,
                    onBack: { route = .overview },
                    onSelect: { route = .sessionDetail($0) }
                )

            case .sessionDetail(let id):
                if let session = store.sessions.first(where: { $0.id == id }) {
                    SessionDetailView(
                        session: session,
                        settings: settings,
                        onBack: { route = .sessions }
                    )
                } else {
                    SessionListView(
                        store: store,
                        settings: settings,
                        period: $sessionPeriod,
                        customStart: $sessionCustomStart,
                        customEnd: $sessionCustomEnd,
                        onBack: { route = .overview },
                        onSelect: { route = .sessionDetail($0) }
                    )
                }
            }
        }
        .environment(\.locale, settings.language.locale)
        .animation(.easeInOut(duration: 0.16), value: route)
        .onChange(of: store.sessions.map(\.id)) { _, _ in
            normalizeMissingSessionRoute()
        }
        .onChange(of: store.loadedSessionQuery) { _, _ in
            normalizeMissingSessionRoute()
        }
    }

    private func normalizeMissingSessionRoute() {
        guard !store.isLoadingSessions,
              store.hasLoadedSessions,
              case .sessionDetail(let id) = route,
              !store.sessions.contains(where: { $0.id == id }) else { return }
        route = .sessions
    }
}

private struct OverviewView: View {
    let store: UsageStore
    @Bindable var settings: AppSettings
    @Bindable var updater: UpdateManager
    let onShowSessions: () -> Void
    let onOpenSettings: @MainActor () -> Void

    private var l10n: AppLocalizer { AppLocalizer(language: settings.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if settings.showEvents {
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
            sessionCallToAction

            if shouldShowUpdateBanner {
                updateBanner
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(settings.showEvents
                     ? l10n.text("overview.events.title")
                     : l10n.text("overview.cost.title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.showEvents {
                    Text("\(store.usage.turnCount)")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(eventsColor)
                } else {
                    Text(l10n.currency(store.usage.monthlyCostUSD))
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(costColor)

                    HStack(spacing: 4) {
                        Text(l10n.format("overview.today", l10n.currency(store.usage.totalCostUSD)))
                        Text("·").foregroundStyle(.tertiary)
                        Text(monthlySourceLabel)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(l10n.plural(
                        singular: "overview.session.count.one",
                        plural: "overview.session.count",
                        count: store.usage.sessionCount
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(l10n.plural(
                        singular: "overview.event.count.one",
                        plural: "overview.event.count",
                        count: store.usage.turnCount
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                displayModeToggle
            }
        }
    }

    private var displayModeToggle: some View {
        HStack(spacing: 0) {
            Button(action: { settings.showEvents = false }) {
                Image(systemName: "dollarsign")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 18)
                    .background(settings.showEvents ? Color.clear : Color.accentColor)
                    .foregroundStyle(settings.showEvents ? Color.secondary : Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.text("overview.cost.title"))
            .accessibilityAddTraits(settings.showEvents ? [] : .isSelected)

            Button(action: { settings.showEvents = true }) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 28, height: 18)
                    .background(settings.showEvents ? Color.accentColor : Color.clear)
                    .foregroundStyle(settings.showEvents ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.text("overview.events.title"))
            .accessibilityAddTraits(settings.showEvents ? .isSelected : [])
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        }
    }

    // MARK: Limits

    private var monthlyEventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading(l10n.text("overview.this_month"))

            let used = store.usage.monthlyTurnCount
            let limit = max(settings.monthlyEventLimit, 1)
            let progress = min(Double(used) / Double(limit), 1)

            ProgressView(value: progress)
                .tint(progressColor(progress))
                .scaleEffect(x: 1, y: 1.5)

            HStack {
                Text(l10n.format("overview.used.events", used))
                Spacer()
                Text(l10n.format("overview.remaining.events", max(limit - used, 0)))
                    .foregroundStyle(progressColor(progress))
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private var monthlyCostSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading(l10n.text("overview.this_month"))

            if let progress = costLimitProgress {
                ProgressView(value: progress.fraction)
                    .tint(progressColor(progress.fraction))
                    .scaleEffect(x: 1, y: 1.5)

                HStack {
                    Text(l10n.format("overview.used.cost", l10n.currency(progress.used)))
                    Spacer()
                    Text(l10n.format("overview.remaining.cost", l10n.currency(progress.remaining)))
                        .foregroundStyle(progressColor(progress.fraction))
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            } else {
                Text(l10n.text("overview.set_limit"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let progress = costLimitProgress, !settings.showEvents {
                Text("\(Int(progress.fraction * 100))%")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private struct CostProgress {
        let used: Double
        let remaining: Double
        let fraction: Double
    }

    private var costLimitProgress: CostProgress? {
        if case .flow(let percentage, let effectiveLimit, _) = store.usage.monthlyCostSource,
           effectiveLimit > 0 {
            return CostProgress(
                used: store.usage.monthlyCostUSD,
                remaining: max(effectiveLimit - store.usage.monthlyCostUSD, 0),
                fraction: min(max(percentage / 100, 0), 1)
            )
        }

        guard settings.monthlyCostLimit > 0 else { return nil }
        let limit = max(settings.monthlyCostLimit, 0.01)
        let used = store.usage.monthlyCostUSD
        return CostProgress(
            used: used,
            remaining: max(limit - used, 0),
            fraction: min(max(used / limit, 0), 1)
        )
    }

    // MARK: Tokens

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.text("overview.tokens"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(l10n.format("overview.tokens.total", formatTokens(store.usage.totalTokens)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 16) {
                tokenPill(
                    l10n.text("overview.tokens.input"),
                    value: store.usage.inputTokens,
                    icon: "arrow.down.circle.fill",
                    color: .blue
                )
                tokenPill(
                    l10n.text("overview.tokens.output"),
                    value: store.usage.outputTokens,
                    icon: "arrow.up.circle.fill",
                    color: .green
                )
            }

            HStack(spacing: 16) {
                tokenPill(
                    l10n.text("overview.tokens.cache_read"),
                    value: store.usage.cacheReadTokens,
                    icon: "square.and.arrow.up.fill",
                    color: .purple
                )
                tokenPill(
                    l10n.text("overview.tokens.cache_write"),
                    value: store.usage.cacheWriteTokens,
                    icon: "square.and.arrow.down.fill",
                    color: .orange
                )
            }
        }
    }

    private func tokenPill(_ label: String, value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(formatTokens(value))
                .font(.system(.caption, design: .monospaced, weight: .medium))
        }
        .frame(maxWidth: .infinity)
    }

    private var unpricedWarning: some View {
        Label(l10n.text("overview.unpriced"), systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(Color.secondary.opacity(0.65))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Breakdown

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.text("overview.models"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.usage.perModel.isEmpty {
                emptyRow(l10n.text("overview.no_data"))
            } else {
                ForEach(Array(store.usage.perModel.prefix(5))) { model in
                    HStack {
                        Text(model.id)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if settings.showEvents {
                            eventCountLabel(model.turnCount)
                        } else {
                            costDailyMonthlyLabel(daily: model.costUSD, monthly: model.monthlyCostUSD)
                        }
                    }
                }
            }
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.text("overview.projects"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.usage.perWorkspace.isEmpty {
                emptyRow(l10n.text("overview.no_sessions"))
            } else {
                ForEach(Array(store.usage.perWorkspace.prefix(5))) { workspace in
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(workspace.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if settings.showEvents {
                            eventCountLabel(workspace.turnCount)
                        } else {
                            costDailyMonthlyLabel(
                                daily: workspace.costUSD,
                                monthly: workspace.monthlyCostUSD
                            )
                        }
                    }
                }
            }
        }
    }

    private func emptyRow(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.tertiary)
    }

    // MARK: Session CTA and updates

    private var sessionCallToAction: some View {
        Button(action: onShowSessions) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.text("overview.view_sessions"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(l10n.text("overview.view_sessions.hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(9)
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n.text("overview.view_sessions"))
        .accessibilityHint(l10n.text("overview.view_sessions.hint"))
    }

    private var shouldShowUpdateBanner: Bool {
        switch updater.state {
        case .available, .downloading, .ready, .installing: true
        case .idle, .checking, .upToDate, .error: false
        }
    }

    private var updateBanner: some View {
        HStack(spacing: 9) {
            if updater.state == .downloading || updater.state == .installing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.format(
                    "footer.update_available",
                    updater.availableRelease?.version.description ?? ""
                ))
                .font(.caption.weight(.medium))
                if let message = updater.errorMessage, updater.state == .ready {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if updater.state == .available {
                Button(l10n.text("footer.install_update")) {
                    updater.installAvailableUpdate()
                }
                .controlSize(.mini)
                .buttonStyle(.borderedProminent)
            } else if updater.state == .ready,
                      let pageURL = updater.availableRelease?.pageURL {
                Button(l10n.text("footer.open_release")) {
                    NSWorkspace.shared.open(pageURL)
                }
                .controlSize(.mini)
            }
        }
        .padding(9)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AppVersion.current.displayName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.quaternary)
                    .help(AppVersion.current.detailedDisplayName)

                if store.lastRefreshed == .distantPast {
                    Text(l10n.text("footer.loading"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(l10n.format("footer.updated", l10n.relative(store.lastRefreshed)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if let sources = store.sources {
                Text(sources.sourceCount == 1
                     ? l10n.text("footer.source.one")
                     : l10n.format("footer.source.many", sources.sourceCount))
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
            .help(l10n.text("footer.refresh"))
            .disabled(store.isLoading)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.caption)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.text("footer.settings"))
            .accessibilityLabel(l10n.text("footer.settings"))

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: "xmark.circle").font(.caption)
            }
            .buttonStyle(.plain)
            .help(l10n.text("footer.quit"))
        }
    }

    // MARK: Formatting and colors

    private var monthlySourceLabel: String {
        switch store.usage.monthlyCostSource {
        case .flow: l10n.text("common.flow")
        case .localFallback: l10n.text("common.local")
        }
    }

    private var costColor: Color {
        guard let progress = costLimitProgress?.fraction else { return .green }
        return progressColor(progress)
    }

    private var eventsColor: Color {
        let limit = max(settings.monthlyEventLimit, 1)
        return progressColor(min(Double(store.usage.monthlyTurnCount) / Double(limit), 1))
    }

    private func progressColor(_ progress: Double) -> Color {
        if progress < 0.6 { return .green }
        if progress < 0.85 { return .orange }
        return .red
    }

    private func eventCountLabel(_ count: Int) -> some View {
        HStack(spacing: 2) {
            Text("\(count)").foregroundStyle(.primary)
            Text(l10n.text("common.events.short"))
                .foregroundStyle(Color.secondary.opacity(0.9))
        }
        .font(.system(.caption, design: .monospaced, weight: .medium))
    }

    private func costDailyMonthlyLabel(daily: Double, monthly: Double) -> some View {
        HStack(spacing: 2) {
            Text(l10n.currency(daily)).foregroundStyle(.primary)
            Text("/").foregroundStyle(Color.secondary.opacity(0.5))
            Text(l10n.currency(monthly)).foregroundStyle(.secondary)
        }
        .font(.system(.caption2, design: .monospaced, weight: .medium))
        .accessibilityLabel(l10n.format(
            "overview.daily_monthly.accessibility",
            l10n.currency(daily),
            l10n.currency(monthly)
        ))
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", locale: l10n.locale, Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", locale: l10n.locale, Double(count) / 1_000)
        }
        return "\(count)"
    }
}

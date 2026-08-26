import AppKit
import SwiftUI

private enum BrandColor {
    static let red = Color(
        red: 244.0 / 255.0,
        green: 37.0 / 255.0,
        blue: 6.0 / 255.0
    )
    static let yellow = Color(
        red: 1.0,
        green: 225.0 / 255.0,
        blue: 0.0
    )
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case usage
    case flow
    case harnesses
    case about

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .usage: "chart.bar.fill"
        case .flow: "point.3.connected.trianglepath.dotted"
        case .harnesses: "cpu.fill"
        case .about: "info.circle.fill"
        }
    }

    var localizationKey: String { "settings.category.\(rawValue)" }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: UsageStore
    @Bindable var updater: UpdateManager
    @Bindable var launchAtLoginManager: LaunchAtLoginManager

    @State private var selection: SettingsCategory? = .general

    private var l10n: AppLocalizer { AppLocalizer(language: settings.language) }

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(l10n.text(category.localizationKey), systemImage: category.icon)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: generalPane
                case .usage: usagePane
                case .flow: flowPane
                case .harnesses: harnessesPane
                case .about: aboutPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 720, height: 500)
        .environment(\.locale, settings.language.locale)
        .onAppear {
            launchAtLoginManager.refreshStatus()
        }
    }

    // MARK: - General

    private var generalPane: some View {
        settingsPane(title: l10n.text("settings.general.title")) {
            settingsCard {
                settingRow(title: l10n.text("settings.language")) {
                    Picker("", selection: $settings.language) {
                        Text(l10n.text("settings.language.system")).tag(AppLanguage.system)
                        Text(l10n.text("settings.language.english")).tag(AppLanguage.english)
                        Text(l10n.text("settings.language.pt_br")).tag(AppLanguage.portugueseBrazil)
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }

                cardDivider

                settingToggle(
                    title: l10n.text("settings.launch_at_login"),
                    description: l10n.text("settings.launch_at_login.description"),
                    isOn: $settings.launchAtLogin
                )
                .onChange(of: settings.launchAtLogin) { _, enabled in
                    launchAtLoginManager.setEnabled(enabled)
                }

                if launchAtLoginManager.status == .requiresApproval {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(l10n.text("settings.launch_at_login.approval"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(l10n.text("settings.open_login_items")) {
                            launchAtLoginManager.openSystemSettings()
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 8)
                } else if let message = launchAtLoginManager.errorMessage {
                    inlineError(message)
                }

                cardDivider

                settingToggle(
                    title: l10n.text("settings.auto_update"),
                    description: l10n.text("settings.auto_update.description"),
                    isOn: $settings.autoUpdateEnabled
                )
                .onChange(of: settings.autoUpdateEnabled) { _, enabled in
                    updater.setAutomaticChecksEnabled(enabled)
                }

                HStack(spacing: 10) {
                    updateStatus
                    Spacer()
                    if updater.state == .available {
                        Button(l10n.text("footer.install_update")) {
                            updater.installAvailableUpdate()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    } else if updater.state == .ready,
                              let pageURL = updater.availableRelease?.pageURL {
                        Button(l10n.text("footer.open_release")) {
                            NSWorkspace.shared.open(pageURL)
                        }
                        .controlSize(.small)
                    }
                    Button(l10n.text("settings.check_updates")) {
                        updater.checkNow()
                    }
                    .controlSize(.small)
                    .disabled(updater.state == .checking || updater.state == .downloading || updater.state == .installing)
                }
                .padding(.top, 10)
                .padding(.bottom, 13)
            }
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.state {
        case .checking:
            statusLabel(l10n.text("settings.update.checking"), icon: "arrow.clockwise", color: .secondary, spinning: true)
        case .upToDate:
            statusLabel(l10n.text("settings.update.up_to_date"), icon: "checkmark.circle.fill", color: .green)
        case .available:
            statusLabel(
                l10n.format("settings.update.available", updater.availableRelease?.version.description ?? ""),
                icon: "arrow.down.circle.fill",
                color: .accentColor
            )
        case .downloading:
            statusLabel(l10n.text("settings.update.downloading"), icon: "arrow.down.circle", color: .accentColor)
        case .ready:
            statusLabel(
                updater.errorMessage ?? l10n.text("footer.install_update"),
                icon: "checkmark.circle.fill",
                color: updater.errorMessage == nil ? .green : .orange
            )
        case .installing:
            statusLabel(l10n.text("settings.update.installing"), icon: "arrow.triangle.2.circlepath", color: .accentColor, spinning: true)
        case .error:
            statusLabel(
                l10n.format("settings.update.error", updater.errorMessage ?? l10n.text("common.not_available")),
                icon: "exclamationmark.triangle.fill",
                color: .red
            )
        case .idle:
            EmptyView()
        }
    }

    private func statusLabel(
        _ title: String,
        icon: String,
        color: Color,
        spinning: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            if spinning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: icon).foregroundStyle(color)
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: - Usage

    private var usagePane: some View {
        settingsPane(title: l10n.text("settings.usage.title")) {
            settingsCard {
                settingRow(
                    title: l10n.text("settings.overview_ranking"),
                    description: l10n.text("settings.overview_ranking.description")
                ) {
                    Picker("", selection: $settings.overviewRanking) {
                        Text(l10n.text("settings.overview_ranking.monthly")).tag(OverviewRankingPeriod.monthly)
                        Text(l10n.text("settings.overview_ranking.daily")).tag(OverviewRankingPeriod.daily)
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }

                cardDivider

                settingRow(
                    title: l10n.text("settings.cost_limit"),
                    description: l10n.text("settings.cost_limit.description")
                ) {
                    HStack(spacing: 4) {
                        Text("$").foregroundStyle(.secondary)
                        TextField("0", value: $settings.monthlyCostLimit, format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 92)
                    }
                }

                cardDivider

                settingRow(title: l10n.text("settings.event_limit")) {
                    TextField("6000", value: $settings.monthlyEventLimit, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                }
            }
        }
    }

    // MARK: - Flow

    private var flowPane: some View {
        settingsPane(title: l10n.text("settings.flow.title")) {
            settingsCard {
                settingToggle(
                    title: l10n.text("settings.flow.enabled"),
                    description: l10n.text("settings.flow.enabled.description"),
                    isOn: $settings.flowEnabled
                )
                .onChange(of: settings.flowEnabled) { _, _ in store.refresh() }

                cardDivider

                settingRow(title: l10n.text("settings.flow.ttl")) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(l10n.format("settings.flow.ttl.value", Int(settings.flowCacheTTL)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: $settings.flowCacheTTL,
                            in: AppSettings.flowCacheTTLRange,
                            step: 30
                        )
                        .frame(width: 210)
                        .accessibilityValue(l10n.format("settings.flow.ttl.value", Int(settings.flowCacheTTL)))
                    }
                }
                .disabled(!settings.flowEnabled)

                cardDivider

                settingRow(
                    title: l10n.text("settings.flow.limit_source"),
                    description: l10n.text("settings.flow.limit.description")
                ) {
                    Picker("", selection: $settings.flowLimitPolicy) {
                        Text(l10n.text("settings.flow.limit.automatic")).tag(FlowLimitPolicy.automatic)
                        Text(l10n.text("settings.flow.limit.individual")).tag(FlowLimitPolicy.individual)
                        Text(l10n.text("settings.flow.limit.tenant")).tag(FlowLimitPolicy.tenant)
                        Text(l10n.text("settings.flow.limit.effective")).tag(FlowLimitPolicy.effective)
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                .disabled(!settings.flowEnabled)
                .onChange(of: settings.flowLimitPolicy) { _, _ in store.refresh() }
            }
        }
    }

    // MARK: - Harnesses

    private var harnessesPane: some View {
        settingsPane(
            title: l10n.text("settings.harnesses.title"),
            subtitle: l10n.text("settings.harnesses.description")
        ) {
            settingsCard {
                harnessToggle(.claudeCode, title: l10n.text("settings.harness.claude"))
                cardDivider
                harnessToggle(.codex, title: l10n.text("settings.harness.codex"))
                cardDivider
                harnessToggle(.opencode, title: l10n.text("settings.harness.opencode"))
            }
        }
    }

    private func harnessToggle(_ harness: Harness, title: String) -> some View {
        settingToggle(
            title: title,
            description: harness == .claudeCode ? "~/.claude/projects" :
                         harness == .codex ? "~/.codex/sessions" :
                         "~/.local/share/opencode/opencode.db",
            isOn: Binding(
                get: { settings.trackedHarnesses.contains(harness) },
                set: { enabled in
                    if enabled {
                        settings.trackedHarnesses.insert(harness)
                    } else {
                        settings.trackedHarnesses.remove(harness)
                    }
                    store.refresh()
                }
            )
        )
    }

    // MARK: - About

    private var aboutPane: some View {
        settingsPane(title: l10n.text("settings.about.title")) {
            VStack(spacing: 18) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 54, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(BrandColor.yellow, BrandColor.red)

                VStack(spacing: 5) {
                    Text(l10n.text("app.name"))
                        .font(.title2.weight(.semibold))
                    Text(l10n.text("settings.about.description"))
                        .foregroundStyle(.secondary)
                    Text(l10n.format("settings.about.version", AppVersion.current.detailedDisplayName))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }

                settingsCard {
                    settingRow(title: l10n.text("settings.about.pricing")) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    cardDivider
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/sozua-ciandt/kill-the-bill")!)
                    } label: {
                        HStack {
                            Text(l10n.text("settings.about.repository"))
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Components

    private func settingsPane<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                content()
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func settingRow<Control: View>(
        title: String,
        description: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 13)
    }

    private func settingToggle(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        settingRow(title: title, description: description) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private var cardDivider: some View {
        Divider().padding(.leading, 1)
    }

    private func inlineError(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

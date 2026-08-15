import SwiftUI

enum SessionCostTotal: Equatable {
    case exact(Double)
    case lowerBound(Double)
    case unavailable
}

struct SessionSubagentRowProjection: Identifiable {
    let id: String
    let agent: SessionSubagentUsage
    let depth: Int
    let ownToolCallCount: Int
}

enum SessionPresentation {
    static func sortedSessions(
        _ sessions: [UsageSession],
        showEvents: Bool
    ) -> [UsageSession] {
        sessions.sorted { left, right in
            if showEvents {
                if left.modelInvocationCount != right.modelInvocationCount {
                    return left.modelInvocationCount > right.modelInvocationCount
                }
            } else {
                switch (left.inclusiveUsage.costUSD, right.inclusiveUsage.costUSD) {
                case let (leftCost?, rightCost?) where leftCost != rightCost:
                    return leftCost > rightCost
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            }

            switch (left.lastActivityAt, right.lastActivityAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if left.id.harness != right.id.harness {
                    return left.id.harness.rawValue < right.id.harness.rawValue
                }
                return left.id.rawValue < right.id.rawValue
            }
        }
    }

    static func visibleCostTotal(for sessions: [UsageSession]) -> SessionCostTotal {
        let usages = sessions.map(\.inclusiveUsage)
        let invocationCount = usages.reduce(0) { $0 + $1.modelInvocationCount }
        let pricedInvocationCount = usages.reduce(0) { $0 + $1.pricedModelInvocationCount }
        let knownCost = usages.reduce(0) { $0 + $1.pricedCostUSD }

        if invocationCount > 0 && pricedInvocationCount == 0 {
            return .unavailable
        }
        if usages.contains(where: { $0.unpricedModelInvocationCount > 0 }) {
            return .lowerBound(knownCost)
        }
        return .exact(knownCost)
    }

    static func subagentRows(
        from agents: [SessionSubagentUsage]
    ) -> [SessionSubagentRowProjection] {
        var result: [SessionSubagentRowProjection] = []

        func append(
            _ agents: [SessionSubagentUsage],
            depth: Int,
            parentPath: String
        ) {
            for agent in agents {
                let pathComponent = "\(agent.id.count):\(agent.id)"
                let path = parentPath.isEmpty ? pathComponent : "\(parentPath)/\(pathComponent)"
                let descendantToolCalls = agent.children.reduce(0) {
                    $0 + $1.toolCallCount
                }
                result.append(SessionSubagentRowProjection(
                    id: path,
                    agent: agent,
                    depth: depth,
                    ownToolCallCount: max(agent.toolCallCount - descendantToolCalls, 0)
                ))
                append(agent.children, depth: depth + 1, parentPath: path)
            }
        }

        append(agents, depth: 0, parentPath: "")
        return result
    }
}

struct SessionListView: View {
    let store: UsageStore
    @Bindable var settings: AppSettings
    @Binding var period: SessionPeriodPreset
    @Binding var customStart: Date
    @Binding var customEnd: Date
    let onBack: () -> Void
    let onSelect: (UsageSessionID) -> Void

    private var l10n: AppLocalizer { AppLocalizer(language: settings.language) }

    private var query: SessionQuery {
        SessionQuery(interval: period.interval(
            customStart: customStart,
            customEnd: customEnd
        ))
    }

    private var isCurrentQueryLoaded: Bool {
        store.loadedSessionQuery == query
    }

    private var isCurrentQueryLoading: Bool {
        store.isLoadingSessions && store.requestedSessionQuery == query
    }

    private var visibleSessions: [UsageSession] {
        guard isCurrentQueryLoaded else { return [] }
        return store.sessions
    }

    private var displayedSessions: [UsageSession] {
        SessionPresentation.sortedSessions(
            visibleSessions,
            showEvents: settings.showEvents
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            navigationHeader
            periodControl

            if period == .custom {
                customRange
            }

            if isCurrentQueryLoaded {
                summaryBar
            } else {
                queryStatusBar
            }
            Divider()

            Group {
                if isCurrentQueryLoading && !isCurrentQueryLoaded {
                    loadingState
                } else if !isCurrentQueryLoaded {
                    pendingQueryState
                } else if visibleSessions.isEmpty {
                    emptyState
                } else {
                    sessionScroll
                }
            }
            .frame(height: period == .custom ? 390 : 430)
        }
        .padding(16)
        .frame(width: 500)
        .onAppear(perform: reloadIfNeeded)
        .onChange(of: period) { _, _ in reload() }
    }

    private var navigationHeader: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(l10n.text("sessions.back"))
            .accessibilityLabel(l10n.text("sessions.back"))

            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.text("sessions.title"))
                    .font(.headline)
                Text(l10n.text("overview.view_sessions.hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isCurrentQueryLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(l10n.text("footer.loading"))
            }

            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(l10n.text("footer.refresh"))
            .accessibilityLabel(l10n.text("footer.refresh"))
            .disabled(isCurrentQueryLoading)
        }
    }

    private var periodControl: some View {
        Picker("", selection: $period) {
            Text(l10n.text("sessions.period.day")).tag(SessionPeriodPreset.day)
            Text(l10n.text("sessions.period.month")).tag(SessionPeriodPreset.month)
            Text(l10n.text("sessions.period.year")).tag(SessionPeriodPreset.year)
            Text(l10n.text("sessions.period.all")).tag(SessionPeriodPreset.all)
            Text(l10n.text("sessions.period.custom")).tag(SessionPeriodPreset.custom)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel(l10n.text("sessions.title"))
    }

    private var customRange: some View {
        HStack(spacing: 12) {
            DatePicker(
                l10n.text("sessions.period.from"),
                selection: $customStart,
                displayedComponents: .date
            )
            DatePicker(
                l10n.text("sessions.period.to"),
                selection: $customEnd,
                displayedComponents: .date
            )
            Spacer(minLength: 0)
            Button(l10n.text("sessions.period.apply"), action: reload)
                .controlSize(.small)
                .disabled(isCurrentQueryLoading || isCurrentQueryLoaded)
        }
        .datePickerStyle(.field)
        .font(.caption)
    }

    private var queryStatusBar: some View {
        HStack {
            Text(isCurrentQueryLoading
                 ? l10n.text("footer.loading")
                 : l10n.text("sessions.period.pending"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var summaryBar: some View {
        HStack {
            Text(l10n.plural(
                singular: "overview.session.count.one",
                plural: "overview.session.count",
                count: visibleSessions.count
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            if settings.showEvents {
                let events = visibleSessions.reduce(0) { $0 + $1.modelInvocationCount }
                let turns = visibleSessions.reduce(0) { $0 + $1.humanTurnCount }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(l10n.plural(
                        singular: "overview.event.count.one",
                        plural: "overview.event.count",
                        count: events
                    ))
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    Text(l10n.plural(
                        singular: "sessions.turns.one",
                        plural: "sessions.turns",
                        count: turns
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            } else {
                Text(totalVisibleCost)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
            }
        }
    }

    private var totalVisibleCost: String {
        switch SessionPresentation.visibleCostTotal(for: visibleSessions) {
        case .exact(let cost):
            return l10n.currency(cost)
        case .lowerBound(let cost):
            return "≥ " + l10n.currency(cost)
        case .unavailable:
            return l10n.text("common.not_available")
        }
    }

    private var sessionScroll: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(displayedSessions) { session in
                    Button {
                        onSelect(session.id)
                    } label: {
                        SessionRow(session: session, settings: settings)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: session))
                    .accessibilityHint(l10n.text("sessions.accessibility.open_detail"))
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().controlSize(.regular)
            Text(l10n.text("footer.loading"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(l10n.text("sessions.empty.title"))
                .font(.headline)
            Text(l10n.text("sessions.empty.message"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var pendingQueryState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(l10n.text("sessions.period.pending"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func reload() {
        store.loadSessions(query: query)
    }

    private func reloadIfNeeded() {
        guard !isCurrentQueryLoaded, !isCurrentQueryLoading else { return }
        reload()
    }

    private func accessibilityLabel(for session: UsageSession) -> String {
        let title = session.title ?? (session.preview.isEmpty
            ? l10n.text("sessions.unknown_topic")
            : session.preview)
        let turns = l10n.plural(
            singular: "sessions.turns.one",
            plural: "sessions.turns",
            count: session.humanTurnCount
        )
        let primaryMetric: String
        if settings.showEvents {
            primaryMetric = l10n.plural(
                singular: "overview.event.count.one",
                plural: "overview.event.count",
                count: session.modelInvocationCount
            )
        } else if let cost = session.inclusiveUsage.costUSD {
            primaryMetric = (session.inclusiveUsage.isCostPartial ? "≥ " : "")
                + l10n.currency(cost)
        } else {
            primaryMetric = l10n.text("common.not_available")
        }
        return [title, session.repositoryName, primaryMetric, turns]
            .joined(separator: ", ")
    }
}

private struct SessionRow: View {
    let session: UsageSession
    let settings: AppSettings

    private var l10n: AppLocalizer { AppLocalizer(language: settings.language) }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            harnessIcon

            VStack(alignment: .leading, spacing: 5) {
                Text(primaryText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let title = session.title,
                   !session.preview.isEmpty,
                   session.preview != title {
                    Text(session.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Label(session.repositoryName, systemImage: "folder.fill")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text(harnessName)
                    if let startedAt = session.startedAt {
                        Text("·")
                        Text(l10n.relative(startedAt))
                            .foregroundStyle(Color.secondary.opacity(0.65))
                            .help(l10n.dateTime(startedAt))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                if settings.showEvents {
                    Text(l10n.plural(
                        singular: "overview.event.count.one",
                        plural: "overview.event.count",
                        count: session.modelInvocationCount
                    ))
                    Text(l10n.plural(
                        singular: "sessions.turns.one",
                        plural: "sessions.turns",
                        count: session.humanTurnCount
                    ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(costLabel)
                    Text(l10n.plural(
                        singular: "sessions.turns.one",
                        plural: "sessions.turns",
                        count: session.humanTurnCount
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .font(.system(.caption, design: .monospaced, weight: .semibold))

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.quaternary)
                .padding(.top, 4)
        }
        .padding(11)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var primaryText: String {
        session.title ?? (session.preview.isEmpty
            ? l10n.text("sessions.unknown_topic")
            : session.preview)
    }

    private var harnessName: String {
        switch session.harness {
        case .claudeCode: l10n.text("harness.claude")
        case .codex: l10n.text("harness.codex")
        }
    }

    private var harnessIcon: some View {
        Image(systemName: session.harness == .claudeCode ? "sparkles" : "terminal.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(session.harness == .claudeCode ? Color.orange : Color.accentColor)
            .frame(width: 26, height: 26)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var costLabel: String {
        guard let cost = session.inclusiveUsage.costUSD else {
            return l10n.text("common.not_available")
        }
        return (session.inclusiveUsage.isCostPartial ? "≥ " : "") + l10n.currency(cost)
    }
}

struct SessionDetailView: View {
    let session: UsageSession
    @Bindable var settings: AppSettings
    let onBack: () -> Void

    private let metricColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 4
    )

    private var l10n: AppLocalizer { AppLocalizer(language: settings.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            detailHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    titleSection
                    metricGrid
                    metadataSection
                    tokenSection
                    modelSection
                    mcpSection
                    subagentSection
                }
                .padding(.bottom, 4)
            }
            .frame(height: 500)
        }
        .padding(16)
        .frame(width: 540)
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(l10n.text("sessions.back"))
            .accessibilityLabel(l10n.text("sessions.back"))

            Text(l10n.text("sessions.detail.title"))
                .font(.headline)
            Spacer()
            Text(session.harness == .claudeCode
                 ? l10n.text("harness.claude")
                 : l10n.text("harness.codex"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.title ?? (session.preview.isEmpty
                ? l10n.text("sessions.unknown_topic")
                : session.preview))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if session.title != nil, !session.preview.isEmpty {
                Text(session.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private var metricGrid: some View {
        LazyVGrid(columns: metricColumns, spacing: 8) {
            metricCard(
                l10n.text("sessions.detail.total_cost"),
                value: sessionCostLabel(session.inclusiveUsage),
                icon: "dollarsign.circle.fill",
                color: .green
            )
            metricCard(
                l10n.text("sessions.detail.turns"),
                value: "\(session.humanTurnCount)",
                icon: "bubble.left.and.bubble.right.fill",
                color: .blue
            )
            metricCard(
                l10n.text("sessions.detail.events"),
                value: "\(session.modelInvocationCount)",
                icon: "arrow.trianglehead.2.clockwise.rotate.90",
                color: .purple
            )
            metricCard(
                l10n.text("sessions.detail.tool_calls"),
                value: "\(session.toolCallCount)",
                icon: "hammer.fill",
                color: .orange
            )
        }
    }

    private func metricCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.callout, design: .rounded, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(9)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var metadataSection: some View {
        detailCard {
            metadataRow(l10n.text("sessions.detail.repository"), value: session.repositoryPath ?? session.repositoryName)
            Divider()
            metadataRow(
                l10n.text("sessions.detail.started"),
                value: session.startedAt.map(l10n.dateTime) ?? l10n.text("common.not_available")
            )
            Divider()
            metadataRow(
                l10n.text("sessions.detail.last_activity"),
                value: session.lastActivityAt.map(l10n.dateTime) ?? l10n.text("common.not_available")
            )
        }
    }

    private func metadataRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.caption)
        .padding(.vertical, 7)
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle(l10n.text("sessions.detail.tokens"))
                Spacer()
                Text(l10n.format(
                    "overview.tokens.total",
                    formatTokens(session.inclusiveUsage.tokens.reportedTotalTokens)
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            detailCard {
                let tokens = session.inclusiveUsage.tokens
                HStack(spacing: 12) {
                    tokenValue(l10n.text("overview.tokens.input"), tokens.inputTokens, color: .blue)
                    tokenValue(l10n.text("overview.tokens.output"), tokens.outputTokens, color: .green)
                    tokenValue(l10n.text("overview.tokens.cache_read"), tokens.cacheReadTokens, color: .purple)
                    tokenValue(l10n.text("overview.tokens.cache_write"), tokens.cacheWriteTokens, color: .orange)
                }
                .padding(.vertical, 9)

                if tokens.reasoningOutputTokens > 0 || tokens.totalOnlyTokens > 0 {
                    Divider()
                    if tokens.reasoningOutputTokens > 0 {
                        supplementalTokenRow(
                            l10n.text("sessions.detail.reasoning_tokens"),
                            value: tokens.reasoningOutputTokens
                        )
                    }
                    if tokens.reasoningOutputTokens > 0 && tokens.totalOnlyTokens > 0 {
                        Divider()
                    }
                    if tokens.totalOnlyTokens > 0 {
                        supplementalTokenRow(
                            l10n.text("sessions.detail.total_only_tokens"),
                            value: tokens.totalOnlyTokens
                        )
                    }
                }

                Divider()

                estimateRow(
                    l10n.text("sessions.detail.tool_tokens"),
                    estimate: aggregateToolEstimate
                )
                Divider()
                estimateRow(
                    l10n.text("sessions.detail.mcp_tokens"),
                    estimate: aggregateMCPEstimate
                )
            }
        }
    }

    private func tokenValue(_ title: String, _ value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(formatTokens(value))
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func supplementalTokenRow(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatTokens(value))
                .font(.system(.caption, design: .monospaced, weight: .semibold))
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func estimateRow(_ title: String, estimate: SessionResultTokenEstimate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption)
                Text(estimateDescription(estimate))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(estimateValue(estimate))
                .font(.system(.caption, design: .monospaced, weight: .semibold))
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(estimateDescription(estimate)), \(estimateValue(estimate))")
    }

    private func estimateDescription(_ estimate: SessionResultTokenEstimate) -> String {
        switch estimate.quality {
        case .partialEstimate:
            return l10n.text("sessions.detail.estimated_partial")
        case .unavailable:
            return l10n.text("sessions.detail.estimate_unavailable")
        case .exact, .estimated:
            return l10n.text("sessions.detail.estimated")
        }
    }

    private func estimateValue(_ estimate: SessionResultTokenEstimate) -> String {
        switch estimate.quality {
        case .unavailable:
            return "—"
        case .partialEstimate:
            return "~\(formatTokens(estimate.value))+"
        case .exact, .estimated:
            return "~\(formatTokens(estimate.value))"
        }
    }

    private var aggregateToolEstimate: SessionResultTokenEstimate {
        session.tools.reduce(into: SessionResultTokenEstimate()) { result, tool in
            result.merge(tool.resultTokens)
        }
    }

    private var aggregateMCPEstimate: SessionResultTokenEstimate {
        session.mcps.reduce(into: SessionResultTokenEstimate()) { result, mcp in
            result.merge(mcp.resultTokens)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(l10n.text("sessions.detail.models"))
            detailCard {
                if session.models.isEmpty {
                    emptyDetailRow(l10n.text("overview.no_data"))
                } else {
                    ForEach(Array(session.models.enumerated()), id: \.element.id) { index, model in
                        HStack {
                            Text(model.id)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text("\(model.usage.modelInvocationCount)×")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(sessionCostLabel(model.usage))
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                        }
                        .padding(.vertical, 7)
                        if index < session.models.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(l10n.text("sessions.detail.mcps"))
            detailCard {
                if session.mcps.isEmpty {
                    emptyDetailRow(l10n.text("sessions.detail.no_mcps"))
                } else {
                    ForEach(Array(session.mcps.enumerated()), id: \.element.id) { index, mcp in
                        HStack(spacing: 8) {
                            Image(systemName: "network")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mcp.server).font(.caption.weight(.medium))
                                Text(mcp.tool).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(mcp.callCount)×")
                                .font(.system(.caption, design: .monospaced))
                            if mcp.resultTokens.quality != .unavailable {
                                Text(estimateValue(mcp.resultTokens))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .help(estimateDescription(mcp.resultTokens))
                            }
                        }
                        .padding(.vertical, 7)
                        if index < session.mcps.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private var subagentSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(l10n.text("sessions.detail.subagents"))
            detailCard {
                if flattenedSubagents.isEmpty {
                    emptyDetailRow(l10n.text("sessions.detail.no_subagents"))
                } else {
                    ForEach(Array(flattenedSubagents.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Color.clear.frame(width: CGFloat(item.depth) * 12)
                                .accessibilityHidden(true)
                            Image(systemName: "person.2.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.agent.name ?? item.agent.kind ?? item.agent.id)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(l10n.plural(
                                    singular: "sessions.tools.one",
                                    plural: "sessions.tools",
                                    count: item.ownToolCallCount
                                ))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(sessionCostLabel(item.agent.ownUsage))
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                        }
                        .padding(.vertical, 7)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(subagentAccessibilityLabel(item))
                        if index < flattenedSubagents.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private var flattenedSubagents: [SessionSubagentRowProjection] {
        SessionPresentation.subagentRows(from: session.subagents)
    }

    private func subagentAccessibilityLabel(
        _ item: SessionSubagentRowProjection
    ) -> String {
        let name = item.agent.name ?? item.agent.kind ?? item.agent.id
        let tools = l10n.plural(
            singular: "sessions.tools.one",
            plural: "sessions.tools",
            count: item.ownToolCallCount
        )
        return [
            name,
            l10n.format("sessions.accessibility.subagent_level", item.depth + 1),
            tools,
            sessionCostLabel(item.agent.ownUsage),
        ].joined(separator: ", ")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 11)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
    }

    private func emptyDetailRow(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    private func sessionCostLabel(_ usage: SessionUsage) -> String {
        guard let cost = usage.costUSD else { return l10n.text("common.not_available") }
        return (usage.isCostPartial ? "≥ " : "") + l10n.currency(cost)
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

import Foundation
import Observation

/// Distinguishes a real "all time" query (`interval == nil`) from the absence
/// of any session load. Keeping the query as a value also lets the UI verify
/// that the visible rows belong to the currently selected period.
struct SessionQuery: Equatable, Sendable {
    let interval: DateInterval?
}

@Observable
@MainActor
final class UsageStore {

    private(set) var usage: DailyUsage = DailyUsage()
    private(set) var sources: LogScanner.DiscoveredSources?
    private(set) var isLoading: Bool = false
    private(set) var isFlowKeyExpired: Bool = false
    private(set) var lastRefreshed: Date = .distantPast
    private(set) var sessions: [UsageSession] = []
    private(set) var isLoadingSessions: Bool = false
    private(set) var sessionsError: String?
    private(set) var requestedSessionQuery: SessionQuery?
    private(set) var loadedSessionQuery: SessionQuery?

    var hasLoadedSessions: Bool { loadedSessionQuery != nil }
    var loadedSessionInterval: DateInterval? { loadedSessionQuery?.interval }

    private let settings: AppSettings
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var refreshGeneration = UUID()
    private var sessionGeneration = UUID()
    private var trackedHarnesses: Set<Harness>

    init(settings: AppSettings) {
        self.settings = settings
        self.trackedHarnesses = settings.snapshot.trackedHarnesses
    }

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        startTimer()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        refreshGeneration = UUID()
        sessionGeneration = UUID()
        isLoading = false
        isLoadingSessions = false
    }

    func refresh() {
        isLoading = true
        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        let snapshot = settings.snapshot

        if snapshot.trackedHarnesses != trackedHarnesses {
            trackedHarnesses = snapshot.trackedHarnesses
            reloadSessionsAfterHarnessChange(settings: snapshot)
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            let (parsed, sources, isExpired) = await Self.loadUsage(settings: snapshot)
            guard !Task.isCancelled, self.refreshGeneration == generation else { return }
            self.usage = parsed
            self.sources = sources
            self.isFlowKeyExpired = isExpired
            self.isLoading = false
            self.lastRefreshed = Date()
            self.refreshTask = nil
        }
    }

    func loadSessions(interval: DateInterval?) {
        loadSessions(query: SessionQuery(interval: interval))
    }

    func loadSessions(query: SessionQuery) {
        startSessionLoad(
            query: query,
            settings: settings.snapshot,
            invalidatingExistingResults: false
        )
    }

    private func startSessionLoad(
        query: SessionQuery,
        settings snapshot: SettingsSnapshot,
        invalidatingExistingResults: Bool
    ) {
        sessionTask?.cancel()

        let belongsToAnotherQuery = loadedSessionQuery != nil && loadedSessionQuery != query
        if invalidatingExistingResults || belongsToAnotherQuery {
            sessions = []
            loadedSessionQuery = nil
        }

        isLoadingSessions = true
        sessionsError = nil
        requestedSessionQuery = query

        let generation = UUID()
        sessionGeneration = generation

        sessionTask = Task { [weak self] in
            guard let self else { return }
            let parsed = await Self.loadSessionUsage(
                settings: snapshot,
                interval: query.interval
            )
            guard !Task.isCancelled,
                  self.sessionGeneration == generation,
                  self.requestedSessionQuery == query else { return }
            self.sessions = parsed
            self.loadedSessionQuery = query
            self.isLoadingSessions = false
            self.sessionTask = nil
        }
    }

    func reloadSessionsIfLoaded() {
        guard let query = requestedSessionQuery ?? loadedSessionQuery else { return }
        loadSessions(query: query)
    }

    func clearLocalCaches() {
        ModelPricing.clearCache()
        SessionFragmentCache.shared.clear()
        FlowBudgetClient.clearTokenCache()
        FlowBudgetClient.clearBudgetCache()
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kill-the-bill")
            .appendingPathComponent("cache")
        try? FileManager.default.removeItem(at: cacheDir)
        refresh()
        reloadSessionsIfLoaded()
    }

    private func reloadSessionsAfterHarnessChange(settings snapshot: SettingsSnapshot) {
        guard let query = requestedSessionQuery ?? loadedSessionQuery else { return }
        startSessionLoad(
            query: query,
            settings: snapshot,
            invalidatingExistingResults: true
        )
    }

    private nonisolated static func loadUsage(
        settings: SettingsSnapshot
    ) async -> (DailyUsage, LogScanner.DiscoveredSources, isFlowKeyExpired: Bool) {
        let sources = LogScanner.discoverSources(trackedHarnesses: settings.trackedHarnesses)
        let pricing = ModelPricing.load()
        let calendar = Calendar.current
        let now = Date()

        let todayFilter = calendar.dateComponents([.year, .month, .day], from: now)
        let monthFilter = calendar.dateComponents([.year, .month], from: now)

        let claudeScan = LogScanner.scanClaudeTranscripts(from: sources.claudeTranscriptDirs)
        let codexScan = LogScanner.scanCodexSessions(from: sources.codexSessionRoot)

        let (claudeToday, claudeMonth) = ClaudeLogParser.parseTranscriptsOverview(
            dirs: sources.claudeTranscriptDirs,
            files: claudeScan.thisMonth,
            pricing: pricing,
            todayFilter: todayFilter,
            monthFilter: monthFilter
        )

        let codexToday = CodexLogParser.parseSessions(files: codexScan.today, pricing: pricing, dateFilter: todayFilter)
        let codexMonth = CodexLogParser.parseSessions(files: codexScan.thisMonth, pricing: pricing, dateFilter: monthFilter)

        let (opencodeToday, opencodeMonth) = OpenCodeDBMonitor.parseUsageOverview(
            dbURL: sources.opencodeDB,
            pricing: pricing,
            todayFilter: todayFilter,
            monthFilter: monthFilter
        )

        let todayCombined = DailyUsage.combined([claudeToday, codexToday, opencodeToday])
        let monthCombined = DailyUsage.combined([claudeMonth, codexMonth, opencodeMonth])

        // Flow Platform's budget API is the primary source for the month-to-date
        // headline figure when available; locally-parsed transcripts remain the
        // fallback (and continue to power today's cost, per-project, per-model
        // breakdowns unconditionally, regardless of Flow's availability).
        var flowUsage: FlowBudgetUsage?
        var isFlowKeyExpired = false
        if settings.flowEnabled {
            flowUsage = FlowBudgetClient.currentUsage()
            if FlowBudgetClient.isStale(flowUsage, ttl: settings.flowCacheTTL) {
                let refreshResult = await FlowBudgetClient.refresh(apiKey: settings.flowApiKey)
                switch refreshResult {
                case .success(let usage):
                    flowUsage = usage
                    isFlowKeyExpired = false
                case .expired:
                    isFlowKeyExpired = true
                    flowUsage = nil
                case .failure, .notConfigured:
                    isFlowKeyExpired = false
                }
            }
        }

        var parsed = todayCombined
        if let flowUsage {
            let resolved = flowUsage.resolved(
                for: settings.flowLimitPolicy,
                customLimit: settings.monthlyCostLimit
            )
            parsed.monthlyCostUSD = resolved.consumedUSD
            parsed.monthlyCostSource = .flow(
                percentage: resolved.percentage,
                effectiveLimit: resolved.limit ?? 0,
                renewalDate: resolved.renewalDate
            )
        } else {
            parsed.monthlyCostUSD = monthCombined.totalCostUSD
            parsed.monthlyCostSource = .localFallback
        }
        parsed.monthlyTurnCount = monthCombined.turnCount

        // Build daily lookup maps for injection into monthly lists.
        let dailyWorkspaceMap = Dictionary(
            todayCombined.perWorkspace.map { ($0.id, $0.costUSD) },
            uniquingKeysWith: { a, _ in a }
        )
        let dailyModelMap = Dictionary(
            todayCombined.perModel.map { ($0.id, $0.costUSD) },
            uniquingKeysWith: { a, _ in a }
        )

        // Use monthly lists as the source so models/projects not used today still appear.
        parsed.perWorkspace = monthCombined.perWorkspace.map { ws in
            var ws = ws
            ws.monthlyCostUSD = ws.costUSD
            ws.costUSD = dailyWorkspaceMap[ws.id] ?? 0
            return ws
        }
        parsed.perModel = monthCombined.perModel.map { m in
            var m = m
            m.monthlyCostUSD = m.costUSD
            m.costUSD = dailyModelMap[m.id] ?? 0
            return m
        }

        return (parsed, sources, isFlowKeyExpired)
    }

    private nonisolated static func loadSessionUsage(
        settings: SettingsSnapshot,
        interval: DateInterval?
    ) async -> [UsageSession] {
        guard !Task.isCancelled else { return [] }
        let sources = LogScanner.discoverSources(trackedHarnesses: settings.trackedHarnesses)
        let pricing = ModelPricing.load()
        guard !Task.isCancelled else { return [] }
        let claudeFiles = LogScanner.findClaudeTranscripts(from: sources.claudeTranscriptDirs, interval: interval)
        let codexFiles = LogScanner.findCodexSessions(from: sources.codexSessionRoot, interval: interval)
        guard !Task.isCancelled else { return [] }

        let parsed = SessionLogParser.parse(
            claudeTranscriptDirs: sources.claudeTranscriptDirs,
            claudeFiles: claudeFiles,
            codexFiles: codexFiles,
            opencodeDB: sources.opencodeDB,
            pricing: pricing,
            interval: interval
        )
        return Task.isCancelled ? [] : parsed
    }

    // MARK: - Timer

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

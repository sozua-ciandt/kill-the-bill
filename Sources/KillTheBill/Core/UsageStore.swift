import Foundation
import Observation

@Observable
@MainActor
final class UsageStore {

    private(set) var usage: DailyUsage = DailyUsage()
    private(set) var sources: LogScanner.DiscoveredSources?
    private(set) var providerDirectory: URL = CustomProviderLoader.providerDirectory
    private(set) var isLoading: Bool = false
    private(set) var lastRefreshed: Date = .distantPast

    private var refreshTimer: Timer?

    func start() {
        refresh()
        startTimer()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        isLoading = true

        Task {
            let (parsed, sources, providerDirectory) = await Self.loadUsage()
            self.usage = parsed
            self.sources = sources
            self.providerDirectory = providerDirectory
            self.isLoading = false
            self.lastRefreshed = Date()
        }
    }

    private nonisolated static func loadUsage() async -> (DailyUsage, LogScanner.DiscoveredSources, URL) {
        let sources = LogScanner.discoverSources()
        let pricing = ModelPricing.load(customProviders: sources.customProviders)
        let calendar = Calendar.current
        let now = Date()

        let todayFilter = calendar.dateComponents([.year, .month, .day], from: now)
        let monthFilter = calendar.dateComponents([.year, .month], from: now)

        let todayClaudeFiles = LogScanner.findTodayClaudeTranscripts(from: sources.claudeTranscriptDirs)
        let monthClaudeFiles = LogScanner.findThisMonthClaudeTranscripts(from: sources.claudeTranscriptDirs)
        let todayCodexFiles = LogScanner.findTodayCodexSessions(from: sources.codexSessionRoot)
        let monthCodexFiles = LogScanner.findThisMonthCodexSessions(from: sources.codexSessionRoot)
        let todayCustomFiles = CustomProviderParser.findTodayFiles(for: sources.customProviders)
        let monthCustomFiles = CustomProviderParser.findThisMonthFiles(for: sources.customProviders)

        let claudeToday = ClaudeLogParser.parseTranscripts(
            dirs: sources.claudeTranscriptDirs,
            files: todayClaudeFiles,
            pricing: pricing,
            dateFilter: todayFilter
        )
        let claudeMonth = ClaudeLogParser.parseTranscripts(
            dirs: sources.claudeTranscriptDirs,
            files: monthClaudeFiles,
            pricing: pricing,
            dateFilter: monthFilter
        )

        let codexToday = CodexLogParser.parseSessions(files: todayCodexFiles, pricing: pricing, dateFilter: todayFilter)
        let codexMonth = CodexLogParser.parseSessions(files: monthCodexFiles, pricing: pricing, dateFilter: monthFilter)

        let customToday = CustomProviderParser.parseProviders(todayCustomFiles, pricing: pricing)
        let customMonth = CustomProviderParser.parseProviders(monthCustomFiles, pricing: pricing)

        let todayCombined = DailyUsage.combined([claudeToday, codexToday, customToday])
        let monthCombined = DailyUsage.combined([claudeMonth, codexMonth, customMonth])

        // Flow Platform's budget API is the primary source for the month-to-date
        // headline figure when available; locally-parsed transcripts remain the
        // fallback (and continue to power today's cost, per-project, per-model
        // breakdowns unconditionally, regardless of Flow's availability).
        var flowUsage = FlowBudgetClient.currentUsage()
        if FlowBudgetClient.isStale(flowUsage) {
            flowUsage = await FlowBudgetClient.refresh() ?? flowUsage
        }

        var parsed = todayCombined
        if let flowUsage {
            parsed.monthlyCostUSD = flowUsage.consumedUSD
            parsed.monthlyCostSource = .flow(
                percentage: flowUsage.percentage,
                effectiveLimit: flowUsage.effectiveLimit,
                renewalDate: flowUsage.renewalDate
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

        return (parsed, sources, CustomProviderLoader.providerDirectory)
    }

    // MARK: - Timer

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

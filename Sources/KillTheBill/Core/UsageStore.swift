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
        let todayClaudeFiles = LogScanner.findTodayClaudeTranscripts(from: sources.claudeTranscriptDirs)
        let monthClaudeFiles = LogScanner.findThisMonthClaudeTranscripts(from: sources.claudeTranscriptDirs)
        let todayCodexFiles = LogScanner.findTodayCodexSessions(from: sources.codexSessionRoot)
        let monthCodexFiles = LogScanner.findThisMonthCodexSessions(from: sources.codexSessionRoot)
        let todayCustomFiles = CustomProviderParser.findTodayFiles(for: sources.customProviders)
        let monthCustomFiles = CustomProviderParser.findThisMonthFiles(for: sources.customProviders)

        let claudeUsage = ClaudeLogParser.parseTranscripts(
            dirs: sources.claudeTranscriptDirs,
            files: todayClaudeFiles,
            pricing: pricing
        )
        let codexUsage = CodexLogParser.parseSessions(files: todayCodexFiles, pricing: pricing)
        let customUsage = CustomProviderParser.parseProviders(todayCustomFiles, pricing: pricing)

        var parsed = DailyUsage.combined([claudeUsage, codexUsage, customUsage])
        parsed.monthlyTurnCount = ClaudeLogParser.countMonthlyTurns(files: monthClaudeFiles)
            + CodexLogParser.countMonthlyTurns(files: monthCodexFiles)
            + CustomProviderParser.countMonthlyTurns(monthCustomFiles)

        return (parsed, sources, CustomProviderLoader.providerDirectory)
    }

    // MARK: - Timer

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

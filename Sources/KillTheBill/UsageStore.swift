import Foundation
import Observation

@Observable
@MainActor
final class UsageStore {

    private(set) var usage: DailyUsage = DailyUsage()
    private(set) var sources: LogScanner.DiscoveredSources?
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
            let (parsed, sources) = await Self.loadUsage()
            self.usage = parsed
            self.sources = sources
            self.isLoading = false
            self.lastRefreshed = Date()
        }
    }

    private nonisolated static func loadUsage() async -> (DailyUsage, LogScanner.DiscoveredSources) {
        let sources = LogScanner.discoverSources()
        let todayFiles = LogScanner.findTodayTranscripts(from: sources.transcriptDirs)
        let monthFiles = LogScanner.findThisMonthTranscripts(from: sources.transcriptDirs)

        var parsed = LogParser.parseTranscripts(dirs: sources.transcriptDirs, files: todayFiles)
        parsed.monthlyTurnCount = LogParser.countMonthlyTurns(files: monthFiles)

        return (parsed, sources)
    }

    // MARK: - Timer

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

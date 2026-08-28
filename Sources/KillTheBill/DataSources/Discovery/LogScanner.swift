import Foundation

/// Discovers local transcript stores for supported coding agents.
enum LogScanner {

    struct DiscoveredSources: Sendable {
        let claudeTranscriptDirs: [URL]
        let codexSessionRoot: URL?
        let opencodeDB: URL?

        init(
            claudeTranscriptDirs: [URL],
            codexSessionRoot: URL? = nil,
            opencodeDB: URL? = nil
        ) {
            self.claudeTranscriptDirs = claudeTranscriptDirs
            self.codexSessionRoot = codexSessionRoot
            self.opencodeDB = opencodeDB
        }

        var sourceCount: Int {
            claudeTranscriptDirs.count
                + (codexSessionRoot == nil ? 0 : 1)
                + (opencodeDB == nil ? 0 : 1)
        }
    }

    static func discoverSources(
        trackedHarnesses: Set<Harness> = Set(Harness.allCases)
    ) -> DiscoveredSources {
        DiscoveredSources(
            claudeTranscriptDirs: trackedHarnesses.contains(.claudeCode)
                ? discoverClaudeTranscriptDirs()
                : [],
            codexSessionRoot: trackedHarnesses.contains(.codex)
                ? discoverCodexSessionRoot()
                : nil,
            opencodeDB: trackedHarnesses.contains(.opencode)
                ? discoverOpenCodeDB()
                : nil
        )
    }

    struct TranscriptScanResult: Sendable {
        let today: [URL]
        let thisMonth: [URL]
        let all: [URL]
    }

    static func scanClaudeTranscripts(from dirs: [URL]) -> TranscriptScanResult {
        let now = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)
        let prevMonth = month == 1 ? 12 : month - 1
        let prevYear  = month == 1 ? year - 1 : year

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var todayFiles: [URL] = []
        var monthFiles: [URL] = []
        var allFiles: [URL] = []

        for dir in dirs {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let entry as URL in enumerator where entry.pathExtension == "jsonl" {
                guard let values = try? entry.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modDate = values.contentModificationDate else {
                    continue
                }
                allFiles.append(entry)
                if calendar.isDateInToday(modDate) {
                    todayFiles.append(entry)
                }
                let m = calendar.component(.month, from: modDate)
                let y = calendar.component(.year, from: modDate)
                if (m == month && y == year) || (m == prevMonth && y == prevYear) {
                    monthFiles.append(entry)
                }
            }
        }

        return TranscriptScanResult(
            today: todayFiles.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path },
            thisMonth: monthFiles.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path },
            all: allFiles.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        )
    }

    static func scanCodexSessions(from root: URL?) -> TranscriptScanResult {
        guard let root else {
            return TranscriptScanResult(today: [], thisMonth: [], all: [])
        }
        let now = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return TranscriptScanResult(today: [], thisMonth: [], all: [])
        }

        var todayFiles: [URL] = []
        var monthFiles: [URL] = []
        var allFiles: [URL] = []

        for case let entry as URL in enumerator where entry.pathExtension == "jsonl" {
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modDate = values.contentModificationDate else {
                continue
            }
            allFiles.append(entry)
            if calendar.isDateInToday(modDate) {
                todayFiles.append(entry)
            }
            if calendar.component(.month, from: modDate) == month &&
               calendar.component(.year, from: modDate) == year {
                monthFiles.append(entry)
            }
        }

        return TranscriptScanResult(
            today: todayFiles.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path },
            thisMonth: monthFiles.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path },
            all: allFiles.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        )
    }

    /// Find today's transcript files across all project dirs.
    static func findTodayClaudeTranscripts(from dirs: [URL]) -> [URL] {
        findClaudeTranscripts(from: dirs) { calendar, date in calendar.isDateInToday(date) }
    }

    /// Find every Claude transcript recursively, regardless of modification date.
    static func findAllClaudeTranscripts(from dirs: [URL]) -> [URL] {
        findClaudeTranscripts(from: dirs) { _, _ in true }
    }

    /// Find Claude transcripts within an interval. If interval is nil, returns all transcripts.
    static func findClaudeTranscripts(from dirs: [URL], interval: DateInterval?) -> [URL] {
        guard let interval else { return findAllClaudeTranscripts(from: dirs) }
        return findClaudeTranscripts(from: dirs) { _, modDate in modDate >= interval.start }
    }

    /// Find this month's transcript files across all project dirs.
    /// Uses a generous mtime window (files modified in the current or previous month) so
    /// long-running conversations that started last month still get included; the parser
    /// then filters individual entries by their internal timestamp.
    static func findThisMonthClaudeTranscripts(from dirs: [URL]) -> [URL] {
        let now = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)
        // Also include files from the previous calendar month in case a conversation
        // started then but still has entries timestamped this month.
        let prevMonth = month == 1 ? 12 : month - 1
        let prevYear  = month == 1 ? year - 1 : year
        return findClaudeTranscripts(from: dirs) { cal, date in
            let m = cal.component(.month, from: date)
            let y = cal.component(.year, from: date)
            return (m == month && y == year) || (m == prevMonth && y == prevYear)
        }
    }

    static func findTodayCodexSessions(from root: URL?) -> [URL] {
        findCodexSessions(from: root) { calendar, date in calendar.isDateInToday(date) }
    }

    /// Find every Codex session recursively, regardless of modification date.
    static func findAllCodexSessions(from root: URL?) -> [URL] {
        findCodexSessions(from: root) { _, _ in true }
    }

    /// Find Codex sessions within an interval. If interval is nil, returns all sessions.
    static func findCodexSessions(from root: URL?, interval: DateInterval?) -> [URL] {
        guard let interval else { return findAllCodexSessions(from: root) }
        return findCodexSessions(from: root) { _, modDate in modDate >= interval.start }
    }

    static func findThisMonthCodexSessions(from root: URL?) -> [URL] {
        let now = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)
        return findCodexSessions(from: root) { cal, date in
            cal.component(.month, from: date) == month &&
            cal.component(.year, from: date) == year
        }
    }

    private static func findClaudeTranscripts(from dirs: [URL], filter: (Calendar, Date) -> Bool) -> [URL] {
        let calendar = Calendar.current
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var files: [URL] = []

        for dir in dirs {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let entry as URL in enumerator where entry.pathExtension == "jsonl" {
                guard let values = try? entry.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modDate = values.contentModificationDate,
                      filter(calendar, modDate) else {
                    continue
                }
                files.append(entry)
            }
        }

        return files.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
    }

    private static func findCodexSessions(from root: URL?, filter: (Calendar, Date) -> Bool) -> [URL] {
        guard let root else { return [] }

        let calendar = Calendar.current
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modDate = values.contentModificationDate,
                  filter(calendar, modDate) else {
                continue
            }
            files.append(file)
        }

        return files.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
    }

    /// Decode a project display name from the encoded directory name.
    /// e.g. "-Users-diogor-Projetos-ia-associacao-medica" → "ia-associacao-medica"
    static func projectName(from dirName: String) -> String {
        let knownParents = Set(["Users", "Projetos", "Projects", "Developer", "Code",
                                "dev", "repos", "src", "workspace", "home", "tmp",
                                "ProjectsAlt"])
        let parts = dirName.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        guard let parentIndex = parts.lastIndex(where: { knownParents.contains($0) }) else {
            return dirName
        }

        var projectStart = parentIndex + 1
        if ["Users", "home"].contains(parts[parentIndex]), projectStart < parts.count {
            projectStart += 1
        }

        let projectParts = projectStart < parts.count ? Array(parts[projectStart...]) : []
        return projectParts.isEmpty ? dirName : projectParts.joined(separator: "-")
    }

    // MARK: - Private

    private static func discoverClaudeTranscriptDirs() -> [URL] {
        let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
    }

    private static func discoverCodexSessionRoot() -> URL? {
        let codexHomePath = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let codexHome = codexHomePath.map(URL.init(fileURLWithPath:)) ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let sessionsRoot = codexHome.appendingPathComponent("sessions")

        guard (try? sessionsRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }

        return sessionsRoot
    }

    private static func discoverOpenCodeDB() -> URL? {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return nil }
        return dbPath
    }
}

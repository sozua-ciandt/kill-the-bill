import Foundation

/// Discovers local transcript stores for supported coding agents.
enum LogScanner {

    struct DiscoveredSources: Sendable {
        let claudeTranscriptDirs: [URL]
        let codexSessionRoot: URL?
        let customProviders: [CustomProviderConfig]

        var sourceCount: Int {
            claudeTranscriptDirs.count
                + (codexSessionRoot == nil ? 0 : 1)
                + customProviders.filter { $0.files != nil && $0.event != nil }.count
        }
    }

    static func discoverSources() -> DiscoveredSources {
        DiscoveredSources(
            claudeTranscriptDirs: discoverClaudeTranscriptDirs(),
            codexSessionRoot: discoverCodexSessionRoot(),
            customProviders: CustomProviderLoader.loadProviders()
        )
    }

    /// Find today's transcript files across all project dirs.
    static func findTodayClaudeTranscripts(from dirs: [URL]) -> [URL] {
        findClaudeTranscripts(from: dirs) { calendar, date in calendar.isDateInToday(date) }
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

        return files
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

        return files
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
}

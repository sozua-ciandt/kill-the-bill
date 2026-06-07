import Foundation

/// Discovers Claude Code transcript directories from ~/.claude/projects/.
enum LogScanner {

    struct DiscoveredSources: Sendable {
        let transcriptDirs: [URL]
    }

    static func discoverSources() -> DiscoveredSources {
        DiscoveredSources(transcriptDirs: discoverTranscriptDirs())
    }

    /// Find today's transcript files across all project dirs.
    static func findTodayTranscripts(from dirs: [URL]) -> [URL] {
        findTranscripts(from: dirs) { calendar, date in calendar.isDateInToday(date) }
    }

    /// Find this month's transcript files across all project dirs.
    static func findThisMonthTranscripts(from dirs: [URL]) -> [URL] {
        let now = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)
        return findTranscripts(from: dirs) { cal, date in
            cal.component(.month, from: date) == month &&
            cal.component(.year, from: date) == year
        }
    }

    private static func findTranscripts(from dirs: [URL], filter: (Calendar, Date) -> Bool) -> [URL] {
        let calendar = Calendar.current
        var files: [URL] = []

        for dir in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            ) else { continue }

            for entry in entries where entry.pathExtension == "jsonl" {
                if let modDate = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate, filter(calendar, modDate) {
                    files.append(entry)
                }
            }
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
        var projectParts: [String] = []
        var pastParents = false

        for part in parts {
            if !pastParents {
                if knownParents.contains(part) { continue }
                pastParents = true   // first non-parent segment = username, skip
                continue
            }
            projectParts.append(part)
        }

        return projectParts.isEmpty ? dirName : projectParts.joined(separator: "-")
    }

    // MARK: - Private

    private static func discoverTranscriptDirs() -> [URL] {
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
}

import Foundation

enum CustomProviderParser {
    static func findTodayFiles(for providers: [CustomProviderConfig]) -> [CustomProviderConfig: [URL]] {
        findFiles(for: providers) { calendar, date in calendar.isDateInToday(date) }
    }

    static func findThisMonthFiles(for providers: [CustomProviderConfig]) -> [CustomProviderConfig: [URL]] {
        let now = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)

        return findFiles(for: providers) { cal, date in
            cal.component(.month, from: date) == month &&
            cal.component(.year, from: date) == year
        }
    }

    static func parseProviders(_ filesByProvider: [CustomProviderConfig: [URL]], pricing: ModelPricing) -> DailyUsage {
        let usages = filesByProvider.map { provider, files in
            parseProvider(provider, files: files, pricing: pricing)
        }
        return DailyUsage.combined(usages)
    }

    static func countMonthlyTurns(_ filesByProvider: [CustomProviderConfig: [URL]]) -> Int {
        filesByProvider.reduce(0) { total, pair in
            total + countTurns(provider: pair.key, files: pair.value)
        }
    }

    private static func parseProvider(_ provider: CustomProviderConfig, files: [URL], pricing: ModelPricing) -> DailyUsage {
        var accumulator = UsageAccumulator()
        guard let event = provider.event else { return accumulator.dailyUsage() }

        for file in files {
            accumulator.registerSession(
                file,
                workspaceID: event.workspaceDefault ?? provider.name ?? provider.id,
                displayName: event.workspaceDefault ?? provider.name ?? provider.id
            )

            for object in jsonObjects(from: file) where matchesProviderEvent(object, provider: provider) {
                let workspace = stringValue(
                    at: event.workspacePath,
                    in: object
                ) ?? event.workspaceDefault ?? provider.name ?? provider.id
                let model = stringValue(
                    at: event.modelPath,
                    in: object
                ) ?? event.modelDefault ?? "unknown"

                let input = intValue(at: event.inputTokensPath, in: object) ?? 0
                let output = intValue(at: event.outputTokensPath, in: object) ?? 0
                let cacheRead = intValue(at: event.cacheReadTokensPath, in: object) ?? 0
                let cacheWrite = intValue(at: event.cacheWriteTokensPath, in: object) ?? 0
                let total = intValue(at: event.totalTokensPath, in: object) ?? (input + output + cacheRead + cacheWrite)

                guard total > 0 else { continue }

                let detailedTokens = input + output + cacheRead + cacheWrite
                let cost = detailedTokens > 0
                    ? pricing.cost(model: model, input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
                    : nil

                accumulator.addTurn(
                    workspaceID: workspace,
                    displayName: workspace,
                    modelID: ModelPricing.normalizeProviderModel(model),
                    input: input,
                    output: output,
                    cacheWrite: cacheWrite,
                    cacheRead: cacheRead,
                    costUSD: cost
                )
            }
        }

        return accumulator.dailyUsage()
    }

    private static func countTurns(provider: CustomProviderConfig, files: [URL]) -> Int {
        guard let event = provider.event else { return 0 }

        return files.reduce(0) { total, file in
            total + jsonObjects(from: file).filter { object in
                guard matchesProviderEvent(object, provider: provider) else { return false }
                let input = intValue(at: event.inputTokensPath, in: object) ?? 0
                let output = intValue(at: event.outputTokensPath, in: object) ?? 0
                let cacheRead = intValue(at: event.cacheReadTokensPath, in: object) ?? 0
                let cacheWrite = intValue(at: event.cacheWriteTokensPath, in: object) ?? 0
                let total = intValue(at: event.totalTokensPath, in: object) ?? (input + output + cacheRead + cacheWrite)
                return total > 0
            }.count
        }
    }

    private static func findFiles(
        for providers: [CustomProviderConfig],
        filter: (Calendar, Date) -> Bool
    ) -> [CustomProviderConfig: [URL]] {
        var filesByProvider: [CustomProviderConfig: [URL]] = [:]

        for provider in providers {
            guard let fileConfig = provider.files, provider.event != nil else { continue }

            let files = fileConfig.roots.flatMap { root in
                discoverFiles(
                    root: expandPath(root),
                    recursive: fileConfig.recursive ?? true,
                    extensions: Set(fileConfig.extensions ?? ["jsonl"]),
                    filter: filter
                )
            }
            if !files.isEmpty {
                filesByProvider[provider] = files
            }
        }

        return filesByProvider
    }

    private static func discoverFiles(
        root: URL,
        recursive: Bool,
        extensions: Set<String>,
        filter: (Calendar, Date) -> Bool
    ) -> [URL] {
        let calendar = Calendar.current
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]

        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return enumerator.compactMap { entry -> URL? in
                guard let file = entry as? URL else { return nil }
                return shouldInclude(file: file, keys: keys, extensions: extensions, calendar: calendar, filter: filter)
                    ? file.standardizedFileURL
                    : nil
            }
        }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files.compactMap { file in
            shouldInclude(file: file, keys: keys, extensions: extensions, calendar: calendar, filter: filter)
                ? file.standardizedFileURL
                : nil
        }
    }

    private static func shouldInclude(
        file: URL,
        keys: Set<URLResourceKey>,
        extensions: Set<String>,
        calendar: Calendar,
        filter: (Calendar, Date) -> Bool
    ) -> Bool {
        guard extensions.contains(file.pathExtension),
              let values = try? file.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let modDate = values.contentModificationDate else {
            return false
        }

        return filter(calendar, modDate)
    }

    private static func jsonObjects(from file: URL) -> [Any] {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: lineData)
        }
    }

    private static func matchesProviderEvent(_ object: Any, provider: CustomProviderConfig) -> Bool {
        guard let event = provider.event else { return false }

        for match in event.matches ?? [] {
            guard stringValue(at: match.path, in: object) == match.equals else {
                return false
            }
        }
        return true
    }

    private static func stringValue(at path: [String]?, in object: Any) -> String? {
        guard let value = value(at: path, in: object) else { return nil }
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(at path: [String]?, in object: Any) -> Int? {
        guard let value = value(at: path, in: object) else { return nil }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func value(at path: [String]?, in object: Any) -> Any? {
        guard let path else { return nil }

        return path.reduce(Optional(object)) { current, component in
            guard let dictionary = current as? [String: Any] else { return nil }
            return dictionary[component]
        }
    }

    private static func expandPath(_ rawPath: String) -> URL {
        if rawPath == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        if rawPath.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(rawPath.dropFirst(2)))
        }

        return URL(fileURLWithPath: rawPath)
    }
}

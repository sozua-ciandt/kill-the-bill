import Foundation
import SQLite3

enum OpenCodeDBMonitor {

    private struct ProjectRecord {
        let id: String
        let worktree: String?
        let name: String?
    }

    private struct SessionRecord {
        let id: String
        let projectID: String
        let directory: String?
        let parentID: String?
        let title: String?
        let agent: String?
        let modelJSON: String?
        let tokensInput: Int
        let tokensOutput: Int
        let tokensReasoning: Int
        let tokensCacheRead: Int
        let tokensCacheWrite: Int
        let timeCreated: Date?
        let timeUpdated: Date?
    }

    // MARK: - Daily / Monthly Usage (Overview)

    static func parseUsage(
        dbURL: URL?,
        pricing: ModelPricing,
        dateFilter: DateComponents?
    ) -> DailyUsage {
        guard let dbURL, let db = openDatabase(at: dbURL) else {
            return DailyUsage()
        }
        defer { sqlite3_close(db) }

        let projects = loadProjects(db: db)
        let sessions = loadSessions(db: db)
        var accumulator = UsageAccumulator()
        let calendar = Calendar.current
        var sessionsWithUsage: Set<String> = []

        var messageQuery = "SELECT id, session_id, time_created, data FROM message ORDER BY time_created ASC;"
        var filterRange: (startMS: Int64, endMS: Int64)? = nil
        if let dateFilter, let range = dateRangeMS(for: dateFilter, calendar: calendar) {
            filterRange = range
            messageQuery = "SELECT id, session_id, time_created, data FROM message WHERE time_created >= ? AND time_created < ? ORDER BY time_created ASC;"
        }

        // 1. Process messages
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, messageQuery, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if let filterRange {
                sqlite3_bind_int64(stmt, 1, filterRange.startMS)
                sqlite3_bind_int64(stmt, 2, filterRange.endMS)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let sessionID = sqliteString(stmt, 1),
                      let session = sessions[sessionID],
                      let dataBytes = sqliteData(stmt, 3),
                      let json = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any],
                      let role = json["role"] as? String,
                      role == "assistant" else {
                    continue
                }

                if filterRange == nil, let filter = dateFilter {
                    let date = sqliteDate(stmt, 2)
                    if let date {
                        guard ParserHelpers.matchesFilter(date, filter: filter, calendar: calendar) else {
                            continue
                        }
                    }
                }

                let (tokens, modelID, providerID) = parseAssistantUsage(json: json, fallbackModelJSON: session.modelJSON)
                guard tokens.knownTotalTokens > 0 || (tokens.inputTokens + tokens.outputTokens) > 0 else {
                    continue
                }

                let (modelKey, cost) = resolvePricingAndModelKey(
                    modelID: modelID,
                    providerID: providerID,
                    pricing: pricing,
                    tokens: tokens
                )

                let project = projects[session.projectID]
                let (workspaceID, displayName) = openCodeWorkspaceName(
                    projectName: project?.name,
                    worktree: project?.worktree,
                    directory: session.directory
                )

                accumulator.addTurn(
                    workspaceID: workspaceID,
                    displayName: displayName,
                    modelID: modelKey,
                    input: tokens.inputTokens,
                    output: tokens.outputTokens,
                    cacheWrite: tokens.cacheWriteTokens,
                    cacheRead: tokens.cacheReadTokens,
                    costUSD: cost
                )

                sessionsWithUsage.insert(sessionID)
            }
        }

        // 2. Fallback for sessions with tokens in session table if no messages were parsed
        for session in sessions.values {
            if sessionsWithUsage.contains(session.id) { continue }
            guard session.tokensInput > 0 || session.tokensOutput > 0 else { continue }

            if let filter = dateFilter, let updated = session.timeUpdated {
                guard ParserHelpers.matchesFilter(updated, filter: filter, calendar: calendar) else {
                    continue
                }
            }

            let (modelID, providerID) = parseModelInfo(from: session.modelJSON)
            let tokens = SessionTokenUsage(
                inputTokens: session.tokensInput,
                outputTokens: session.tokensOutput,
                cacheWriteTokens: session.tokensCacheWrite,
                cacheReadTokens: session.tokensCacheRead,
                reasoningOutputTokens: session.tokensReasoning
            )

            let (modelKey, cost) = resolvePricingAndModelKey(
                modelID: modelID,
                providerID: providerID,
                pricing: pricing,
                tokens: tokens
            )

            let project = projects[session.projectID]
            let (workspaceID, displayName) = openCodeWorkspaceName(
                projectName: project?.name,
                worktree: project?.worktree,
                directory: session.directory
            )

            accumulator.addTurn(
                workspaceID: workspaceID,
                displayName: displayName,
                modelID: modelKey,
                input: tokens.inputTokens,
                output: tokens.outputTokens,
                cacheWrite: tokens.cacheWriteTokens,
                cacheRead: tokens.cacheReadTokens,
                costUSD: cost
            )

            sessionsWithUsage.insert(session.id)
        }

        // 3. Register sessions
        for sessionID in sessionsWithUsage {
            guard let session = sessions[sessionID] else { continue }
            let project = projects[session.projectID]
            let (workspaceID, displayName) = openCodeWorkspaceName(
                projectName: project?.name,
                worktree: project?.worktree,
                directory: session.directory
            )
            let rootID = (session.parentID?.isEmpty == false) ? session.parentID! : session.id
            accumulator.registerSession(
                id: "opencode:\(rootID)",
                workspaceID: workspaceID,
                displayName: displayName,
                lastActivity: session.timeUpdated ?? session.timeCreated
            )
        }

        return accumulator.dailyUsage()
    }

    static func parseUsageOverview(
        dbURL: URL?,
        pricing: ModelPricing,
        todayFilter: DateComponents,
        monthFilter: DateComponents
    ) -> (today: DailyUsage, month: DailyUsage) {
        guard let dbURL, let db = openDatabase(at: dbURL) else {
            return (DailyUsage(), DailyUsage())
        }
        defer { sqlite3_close(db) }

        let projects = loadProjects(db: db)
        let sessions = loadSessions(db: db)
        var todayAccumulator = UsageAccumulator()
        var monthAccumulator = UsageAccumulator()
        let calendar = Calendar.current
        var todaySessions: Set<String> = []
        var monthSessions: Set<String> = []

        let monthRange = dateRangeMS(for: monthFilter, calendar: calendar)
        let todayRange = dateRangeMS(for: todayFilter, calendar: calendar)

        var messageQuery = "SELECT id, session_id, time_created, data FROM message ORDER BY time_created ASC;"
        if monthRange != nil {
            messageQuery = "SELECT id, session_id, time_created, data FROM message WHERE time_created >= ? AND time_created < ? ORDER BY time_created ASC;"
        }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, messageQuery, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if let monthRange {
                sqlite3_bind_int64(stmt, 1, monthRange.startMS)
                sqlite3_bind_int64(stmt, 2, monthRange.endMS)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let sessionID = sqliteString(stmt, 1),
                      let session = sessions[sessionID],
                      let dataBytes = sqliteData(stmt, 3),
                      let json = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any],
                      let role = json["role"] as? String,
                      role == "assistant" else {
                    continue
                }

                let timeCreatedMS = sqlite3_column_int64(stmt, 2)
                let date = timeCreatedMS > 0 ? Date(timeIntervalSince1970: TimeInterval(timeCreatedMS) / 1000) : nil

                let matchesMonth: Bool
                if monthRange != nil {
                    matchesMonth = true
                } else if let date {
                    matchesMonth = ParserHelpers.matchesFilter(date, filter: monthFilter, calendar: calendar)
                } else {
                    matchesMonth = false
                }

                guard matchesMonth else { continue }

                let matchesToday: Bool
                if let todayRange {
                    matchesToday = timeCreatedMS >= todayRange.startMS && timeCreatedMS < todayRange.endMS
                } else if let date {
                    matchesToday = ParserHelpers.matchesFilter(date, filter: todayFilter, calendar: calendar)
                } else {
                    matchesToday = false
                }

                let (tokens, modelID, providerID) = parseAssistantUsage(json: json, fallbackModelJSON: session.modelJSON)
                guard tokens.knownTotalTokens > 0 || (tokens.inputTokens + tokens.outputTokens) > 0 else {
                    continue
                }

                let (modelKey, cost) = resolvePricingAndModelKey(
                    modelID: modelID,
                    providerID: providerID,
                    pricing: pricing,
                    tokens: tokens
                )

                let project = projects[session.projectID]
                let (workspaceID, displayName) = openCodeWorkspaceName(
                    projectName: project?.name,
                    worktree: project?.worktree,
                    directory: session.directory
                )

                monthAccumulator.addTurn(
                    workspaceID: workspaceID,
                    displayName: displayName,
                    modelID: modelKey,
                    input: tokens.inputTokens,
                    output: tokens.outputTokens,
                    cacheWrite: tokens.cacheWriteTokens,
                    cacheRead: tokens.cacheReadTokens,
                    costUSD: cost
                )
                monthSessions.insert(sessionID)

                if matchesToday {
                    todayAccumulator.addTurn(
                        workspaceID: workspaceID,
                        displayName: displayName,
                        modelID: modelKey,
                        input: tokens.inputTokens,
                        output: tokens.outputTokens,
                        cacheWrite: tokens.cacheWriteTokens,
                        cacheRead: tokens.cacheReadTokens,
                        costUSD: cost
                    )
                    todaySessions.insert(sessionID)
                }
            }
        }

        // 2. Fallback for sessions
        for session in sessions.values {
            guard session.tokensInput > 0 || session.tokensOutput > 0 else { continue }

            let sessionUpdatedMS = session.timeUpdated.map { Int64($0.timeIntervalSince1970 * 1000) } ??
                                   session.timeCreated.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0

            let inMonth: Bool
            if let monthRange {
                inMonth = sessionUpdatedMS >= monthRange.startMS && sessionUpdatedMS < monthRange.endMS
            } else if let updated = session.timeUpdated ?? session.timeCreated {
                inMonth = ParserHelpers.matchesFilter(updated, filter: monthFilter, calendar: calendar)
            } else {
                inMonth = false
            }

            let inToday: Bool
            if let todayRange {
                inToday = sessionUpdatedMS >= todayRange.startMS && sessionUpdatedMS < todayRange.endMS
            } else if let updated = session.timeUpdated ?? session.timeCreated {
                inToday = ParserHelpers.matchesFilter(updated, filter: todayFilter, calendar: calendar)
            } else {
                inToday = false
            }

            guard inMonth || inToday else { continue }

            let (modelID, providerID) = parseModelInfo(from: session.modelJSON)
            let tokens = SessionTokenUsage(
                inputTokens: session.tokensInput,
                outputTokens: session.tokensOutput,
                cacheWriteTokens: session.tokensCacheWrite,
                cacheReadTokens: session.tokensCacheRead,
                reasoningOutputTokens: session.tokensReasoning
            )
            let (modelKey, cost) = resolvePricingAndModelKey(
                modelID: modelID,
                providerID: providerID,
                pricing: pricing,
                tokens: tokens
            )
            let project = projects[session.projectID]
            let (workspaceID, displayName) = openCodeWorkspaceName(
                projectName: project?.name,
                worktree: project?.worktree,
                directory: session.directory
            )

            if inMonth, !monthSessions.contains(session.id) {
                monthAccumulator.addTurn(
                    workspaceID: workspaceID,
                    displayName: displayName,
                    modelID: modelKey,
                    input: tokens.inputTokens,
                    output: tokens.outputTokens,
                    cacheWrite: tokens.cacheWriteTokens,
                    cacheRead: tokens.cacheReadTokens,
                    costUSD: cost
                )
                monthSessions.insert(session.id)
            }

            if inToday, !todaySessions.contains(session.id) {
                todayAccumulator.addTurn(
                    workspaceID: workspaceID,
                    displayName: displayName,
                    modelID: modelKey,
                    input: tokens.inputTokens,
                    output: tokens.outputTokens,
                    cacheWrite: tokens.cacheWriteTokens,
                    cacheRead: tokens.cacheReadTokens,
                    costUSD: cost
                )
                todaySessions.insert(session.id)
            }
        }

        // 3. Register sessions
        for sessionID in monthSessions {
            guard let session = sessions[sessionID] else { continue }
            let project = projects[session.projectID]
            let (workspaceID, displayName) = openCodeWorkspaceName(
                projectName: project?.name,
                worktree: project?.worktree,
                directory: session.directory
            )
            let rootID = (session.parentID?.isEmpty == false) ? session.parentID! : session.id
            monthAccumulator.registerSession(
                id: "opencode:\(rootID)",
                workspaceID: workspaceID,
                displayName: displayName,
                lastActivity: session.timeUpdated ?? session.timeCreated
            )
        }

        for sessionID in todaySessions {
            guard let session = sessions[sessionID] else { continue }
            let project = projects[session.projectID]
            let (workspaceID, displayName) = openCodeWorkspaceName(
                projectName: project?.name,
                worktree: project?.worktree,
                directory: session.directory
            )
            let rootID = (session.parentID?.isEmpty == false) ? session.parentID! : session.id
            todayAccumulator.registerSession(
                id: "opencode:\(rootID)",
                workspaceID: workspaceID,
                displayName: displayName,
                lastActivity: session.timeUpdated ?? session.timeCreated
            )
        }

        return (todayAccumulator.dailyUsage(), monthAccumulator.dailyUsage())
    }

    // MARK: - Sessions List & Detail

    static func parseSessions(
        dbURL: URL?,
        pricing: ModelPricing,
        interval: DateInterval?
    ) -> [ParsedSessionFragment] {
        guard let dbURL, let db = openDatabase(at: dbURL) else {
            return []
        }
        defer { sqlite3_close(db) }

        let projects = loadProjects(db: db)
        let sessions = loadSessions(db: db)
        var fragments: [String: ParsedSessionFragment] = [:]

        // Initialize fragments for all sessions
        for session in sessions.values {
            let project = projects[session.projectID]
            let (_, displayName) = openCodeWorkspaceName(
                projectName: project?.name,
                worktree: project?.worktree,
                directory: session.directory
            )

            var repositoryPath: String? = nil
            if let dir = session.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty, dir != "/" {
                repositoryPath = dir
            } else if let wt = project?.worktree?.trimmingCharacters(in: .whitespacesAndNewlines), !wt.isEmpty, wt != "/" {
                repositoryPath = wt
            }

            let isSubagent = (session.parentID?.isEmpty == false)
            var fragment = ParsedSessionFragment(
                harness: .opencode,
                id: session.id,
                parentID: isSubagent ? session.parentID : nil,
                isSubagent: isSubagent,
                name: session.agent,
                title: session.title,
                repositoryFallbackName: displayName
            )
            fragment.repositoryPath = repositoryPath
            fragment.observeLifetimeDate(session.timeCreated)
            fragment.observeLifetimeDate(session.timeUpdated)

            fragments[session.id] = fragment
        }

        var messageQuery = "SELECT id, session_id, time_created, data FROM message ORDER BY time_created ASC;"
        var partQuery = "SELECT id, message_id, session_id, time_created, data FROM part ORDER BY time_created ASC;"
        var intervalRange: (startMS: Int64, endMS: Int64)? = nil
        if let interval {
            let startMS = Int64(interval.start.timeIntervalSince1970 * 1000)
            let endMS = Int64(interval.end.timeIntervalSince1970 * 1000)
            intervalRange = (startMS, endMS)
            messageQuery = "SELECT id, session_id, time_created, data FROM message WHERE time_created >= ? AND time_created < ? ORDER BY time_created ASC;"
            partQuery = "SELECT id, message_id, session_id, time_created, data FROM part WHERE time_created >= ? AND time_created < ? ORDER BY time_created ASC;"
        }

        // Parse messages
        var stmtMsg: OpaquePointer?
        if sqlite3_prepare_v2(db, messageQuery, -1, &stmtMsg, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmtMsg) }
            if let intervalRange {
                sqlite3_bind_int64(stmtMsg, 1, intervalRange.startMS)
                sqlite3_bind_int64(stmtMsg, 2, intervalRange.endMS)
            }

            while sqlite3_step(stmtMsg) == SQLITE_ROW {
                guard let sessionID = sqliteString(stmtMsg, 1),
                      var fragment = fragments[sessionID],
                      let dataBytes = sqliteData(stmtMsg, 3),
                      let json = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any],
                      let role = json["role"] as? String else {
                    continue
                }

                let messageID = sqliteString(stmtMsg, 0)
                let date = sqliteDate(stmtMsg, 2)
                fragment.observeLifetimeDate(date)

                if role == "user" {
                    fragment.addHumanTurn(id: messageID, at: date, interval: interval)
                } else if role == "assistant" {
                    let session = sessions[sessionID]
                    let (tokens, modelID, providerID) = parseAssistantUsage(
                        json: json,
                        fallbackModelJSON: session?.modelJSON
                    )
                    let (modelKey, cost) = resolvePricingAndModelKey(
                        modelID: modelID,
                        providerID: providerID,
                        pricing: pricing,
                        tokens: tokens
                    )
                    fragment.addInvocation(
                        model: modelKey,
                        tokens: tokens,
                        costUSD: cost,
                        at: date,
                        interval: interval
                    )
                }

                fragments[sessionID] = fragment
            }
        }

        // Parse parts (for previews and tools)
        var stmtPart: OpaquePointer?
        if sqlite3_prepare_v2(db, partQuery, -1, &stmtPart, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmtPart) }
            if let intervalRange {
                sqlite3_bind_int64(stmtPart, 1, intervalRange.startMS)
                sqlite3_bind_int64(stmtPart, 2, intervalRange.endMS)
            }

            while sqlite3_step(stmtPart) == SQLITE_ROW {
                guard let sessionID = sqliteString(stmtPart, 2),
                      var fragment = fragments[sessionID],
                      let dataBytes = sqliteData(stmtPart, 4),
                      let json = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any],
                      let type = json["type"] as? String else {
                    continue
                }

                let partID = sqliteString(stmtPart, 0) ?? UUID().uuidString
                let date = sqliteDate(stmtPart, 3)
                fragment.observeLifetimeDate(date)

                if type == "text" {
                    if fragment.preview == nil, let text = json["text"] as? String {
                        fragment.preview = sanitizedSessionPreview(text)
                    }
                } else if type == "tool" {
                    let toolName = json["tool"] as? String ?? "tool"
                    let callID = json["callID"] as? String ?? partID
                    let state = json["state"] as? [String: Any]
                    let status = state?["status"] as? String
                    let isError = (status == "error")
                    let output = state?["output"]

                    fragment.addToolCall(
                        id: callID,
                        name: toolName,
                        at: date,
                        interval: interval
                    )
                    fragment.addToolResult(
                        callID: callID,
                        payload: output,
                        isError: isError,
                        at: date,
                        interval: interval
                    )
                }

                fragments[sessionID] = fragment
            }
        }

        // Post-process fragments
        return fragments.values.map { frag in
            var fragment = frag
            let session = sessions[fragment.id]

            // Fallback for sessions with 0 parsed assistant invocations
            if fragment.ownUsage.modelInvocationCount == 0,
               let session,
               (session.tokensInput > 0 || session.tokensOutput > 0) {
                let (modelID, providerID) = parseModelInfo(from: session.modelJSON)
                let tokens = SessionTokenUsage(
                    inputTokens: session.tokensInput,
                    outputTokens: session.tokensOutput,
                    cacheWriteTokens: session.tokensCacheWrite,
                    cacheReadTokens: session.tokensCacheRead,
                    reasoningOutputTokens: session.tokensReasoning
                )
                let (modelKey, cost) = resolvePricingAndModelKey(
                    modelID: modelID,
                    providerID: providerID,
                    pricing: pricing,
                    tokens: tokens
                )
                let date = session.timeUpdated ?? session.timeCreated
                fragment.addInvocation(
                    model: modelKey,
                    tokens: tokens,
                    costUSD: cost,
                    at: date,
                    interval: interval
                )
                if fragment.humanTurnCount == 0 {
                    fragment.addHumanTurn(id: nil, at: date, interval: interval)
                }
            }

            if fragment.preview == nil {
                fragment.preview = sanitizedSessionPreview(session?.title)
            }

            if interval == nil {
                fragment.hasActivityInSlice = true
            }

            return fragment
        }
    }

    // MARK: - SQLite & Extraction Helpers

    private static func openDatabase(at url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    private static func sqliteString(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }

    private static func sqliteInt(_ stmt: OpaquePointer?, _ col: Int32) -> Int {
        Int(sqlite3_column_int(stmt, col))
    }

    private static func sqliteDate(_ stmt: OpaquePointer?, _ col: Int32) -> Date? {
        let ms = sqlite3_column_int64(stmt, col)
        guard ms > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    private static func sqliteData(_ stmt: OpaquePointer?, _ col: Int32) -> Data? {
        guard let blob = sqlite3_column_blob(stmt, col) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, col))
        guard count > 0 else { return nil }
        return Data(bytes: blob, count: count)
    }

    private static func dateRangeMS(for filter: DateComponents, calendar: Calendar) -> (startMS: Int64, endMS: Int64)? {
        guard let date = calendar.date(from: filter) else { return nil }
        let component: Calendar.Component = filter.day != nil ? .day : .month
        guard let interval = calendar.dateInterval(of: component, for: date) else { return nil }
        let startMS = Int64(interval.start.timeIntervalSince1970 * 1000)
        let endMS = Int64(interval.end.timeIntervalSince1970 * 1000)
        return (startMS, endMS)
    }

    private static func loadProjects(db: OpaquePointer) -> [String: ProjectRecord] {
        var projects: [String: ProjectRecord] = [:]
        let query = "SELECT id, worktree, name FROM project;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = sqliteString(stmt, 0) else { continue }
                let worktree = sqliteString(stmt, 1)
                let name = sqliteString(stmt, 2)
                projects[id] = ProjectRecord(id: id, worktree: worktree, name: name)
            }
        }
        return projects
    }

    private static func loadSessions(db: OpaquePointer) -> [String: SessionRecord] {
        var sessions: [String: SessionRecord] = [:]
        let query = "SELECT id, project_id, directory, parent_id, title, agent, model, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated FROM session;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = sqliteString(stmt, 0),
                      let projectID = sqliteString(stmt, 1) else { continue }
                let directory = sqliteString(stmt, 2)
                let parentID = sqliteString(stmt, 3)
                let title = sqliteString(stmt, 4)
                let agent = sqliteString(stmt, 5)
                let model = sqliteString(stmt, 6)
                let tokensInput = sqliteInt(stmt, 7)
                let tokensOutput = sqliteInt(stmt, 8)
                let tokensReasoning = sqliteInt(stmt, 9)
                let tokensCacheRead = sqliteInt(stmt, 10)
                let tokensCacheWrite = sqliteInt(stmt, 11)
                let timeCreated = sqliteDate(stmt, 12)
                let timeUpdated = sqliteDate(stmt, 13)

                sessions[id] = SessionRecord(
                    id: id,
                    projectID: projectID,
                    directory: directory,
                    parentID: parentID,
                    title: title,
                    agent: agent,
                    modelJSON: model,
                    tokensInput: tokensInput,
                    tokensOutput: tokensOutput,
                    tokensReasoning: tokensReasoning,
                    tokensCacheRead: tokensCacheRead,
                    tokensCacheWrite: tokensCacheWrite,
                    timeCreated: timeCreated,
                    timeUpdated: timeUpdated
                )
            }
        }
        return sessions
    }

    private static func parseModelInfo(from jsonString: String?) -> (modelID: String?, providerID: String?) {
        guard let jsonString,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let modelID = json["id"] as? String
            ?? json["modelID"] as? String
            ?? (json["model"] as? [String: Any])?["modelID"] as? String
            ?? (json["model"] as? [String: Any])?["id"] as? String
        let providerID = json["providerID"] as? String
            ?? (json["model"] as? [String: Any])?["providerID"] as? String
        return (modelID, providerID)
    }

    private static func parseAssistantUsage(
        json: [String: Any],
        fallbackModelJSON: String?
    ) -> (tokens: SessionTokenUsage, modelID: String?, providerID: String?) {
        var input = 0
        var output = 0
        var cacheWrite = 0
        var cacheRead = 0
        var reasoning = 0

        if let tokensObj = json["tokens"] as? [String: Any] {
            input = tokensObj["input"] as? Int ?? 0
            output = tokensObj["output"] as? Int ?? 0
            reasoning = tokensObj["reasoning"] as? Int ?? 0
            if let cacheObj = tokensObj["cache"] as? [String: Any] {
                cacheWrite = cacheObj["write"] as? Int ?? 0
                cacheRead = cacheObj["read"] as? Int ?? 0
            }
        }

        let tokens = SessionTokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheWriteTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            reasoningOutputTokens: reasoning
        )

        var modelID = json["modelID"] as? String
            ?? (json["model"] as? [String: Any])?["modelID"] as? String
            ?? (json["model"] as? [String: Any])?["id"] as? String
        var providerID = json["providerID"] as? String
            ?? (json["model"] as? [String: Any])?["providerID"] as? String

        if modelID == nil || providerID == nil {
            let (fallbackModel, fallbackProvider) = parseModelInfo(from: fallbackModelJSON)
            if modelID == nil { modelID = fallbackModel }
            if providerID == nil { providerID = fallbackProvider }
        }

        return (tokens, modelID, providerID)
    }

    private static func resolvePricingAndModelKey(
        modelID: String?,
        providerID: String?,
        pricing: ModelPricing,
        tokens: SessionTokenUsage
    ) -> (modelKey: String, cost: Double?) {
        guard let modelID, !modelID.isEmpty else {
            return ("unknown", nil)
        }
        let rawModel: String
        if let providerID, !providerID.isEmpty {
            rawModel = "\(providerID)/\(modelID)"
        } else {
            rawModel = modelID
        }
        let modelKey = ModelPricing.normalizeModel(rawModel)
        let cost = pricing.cost(
            model: rawModel,
            input: tokens.inputTokens,
            output: tokens.outputTokens,
            cacheWrite: tokens.cacheWriteTokens,
            cacheRead: tokens.cacheReadTokens
        ) ?? pricing.cost(
            model: modelID,
            input: tokens.inputTokens,
            output: tokens.outputTokens,
            cacheWrite: tokens.cacheWriteTokens,
            cacheRead: tokens.cacheReadTokens
        )
        return (modelKey.isEmpty ? ModelPricing.normalizeModel(modelID) : modelKey, cost)
    }

    private static func openCodeWorkspaceName(
        projectName: String?,
        worktree: String?,
        directory: String?
    ) -> (workspaceID: String, displayName: String) {
        if let projectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !projectName.isEmpty {
            return (projectName, projectName)
        }
        if let worktree = worktree?.trimmingCharacters(in: .whitespacesAndNewlines), !worktree.isEmpty, worktree != "/" {
            let name = sessionRepositoryName(path: worktree, fallback: "")
            if !name.isEmpty {
                return (name, name)
            }
        }
        if let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty, directory != "/" {
            let name = sessionRepositoryName(path: directory, fallback: "")
            if !name.isEmpty {
                return (name, name)
            }
        }
        return ("OpenCode", "OpenCode")
    }
}
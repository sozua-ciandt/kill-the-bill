import Foundation

struct WorkspaceUsage: Identifiable, Sendable {
    let id: String
    var displayName: String
    var costUSD: Double
    var monthlyCostUSD: Double = 0
    var inputTokens: Int
    var outputTokens: Int
    var cacheWriteTokens: Int
    var cacheReadTokens: Int
    var sessionCount: Int
    var turnCount: Int
    var unpricedTurnCount: Int
}

struct ModelUsage: Identifiable, Sendable {
    let id: String
    var costUSD: Double
    var monthlyCostUSD: Double = 0
    var turnCount: Int
    var unpricedTurnCount: Int
}

enum MonthlyCostSource: Sendable, Equatable {
    /// Month-to-date figure comes from Flow Platform's org-configured budget API.
    case flow(percentage: Double, effectiveLimit: Double, renewalDate: String)
    /// Flow was unavailable (no token, network error, auth failure) — fell back
    /// to summing locally-parsed transcripts, same as before Flow was added.
    case localFallback
}

// Holds today's usage in most fields. monthlyCostUSD, monthlyTurnCount, and the
// perWorkspace/perModel lists are overwritten with month-to-date values after load.
// perWorkspace/perModel monthly breakdowns always come from local parsing, even
// when the headline monthlyCostUSD is sourced from Flow — Flow only reports an
// aggregate org-wide figure, not per-project/per-model detail.
struct DailyUsage: Sendable {
    var totalCostUSD: Double = 0
    var monthlyCostUSD: Double = 0
    var monthlyCostSource: MonthlyCostSource = .localFallback
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheReadTokens: Int = 0
    var sessionCount: Int = 0
    var turnCount: Int = 0
    var unpricedTurnCount: Int = 0
    var monthlyTurnCount: Int = 0
    var lastUpdated: Date = .distantPast
    var perWorkspace: [WorkspaceUsage] = []
    var perModel: [ModelUsage] = []

    var totalTokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }
    var hasUnpricedUsage: Bool { unpricedTurnCount > 0 }

    static func combined(_ usages: [DailyUsage]) -> DailyUsage {
        var workspaces: [String: WorkspaceUsage] = [:]
        var models: [String: ModelUsage] = [:]
        var combined = DailyUsage()

        for usage in usages {
            combined.totalCostUSD += usage.totalCostUSD
            combined.monthlyCostUSD += usage.monthlyCostUSD
            combined.inputTokens += usage.inputTokens
            combined.outputTokens += usage.outputTokens
            combined.cacheWriteTokens += usage.cacheWriteTokens
            combined.cacheReadTokens += usage.cacheReadTokens
            combined.sessionCount += usage.sessionCount
            combined.turnCount += usage.turnCount
            combined.unpricedTurnCount += usage.unpricedTurnCount
            combined.monthlyTurnCount += usage.monthlyTurnCount
            combined.lastUpdated = max(combined.lastUpdated, usage.lastUpdated)

            for workspace in usage.perWorkspace {
                if var existing = workspaces[workspace.id] {
                    existing.costUSD += workspace.costUSD
                    existing.monthlyCostUSD += workspace.monthlyCostUSD
                    existing.inputTokens += workspace.inputTokens
                    existing.outputTokens += workspace.outputTokens
                    existing.cacheWriteTokens += workspace.cacheWriteTokens
                    existing.cacheReadTokens += workspace.cacheReadTokens
                    existing.sessionCount += workspace.sessionCount
                    existing.turnCount += workspace.turnCount
                    existing.unpricedTurnCount += workspace.unpricedTurnCount
                    workspaces[workspace.id] = existing
                } else {
                    workspaces[workspace.id] = workspace
                }
            }

            for model in usage.perModel {
                if var existing = models[model.id] {
                    existing.costUSD += model.costUSD
                    existing.monthlyCostUSD += model.monthlyCostUSD
                    existing.turnCount += model.turnCount
                    existing.unpricedTurnCount += model.unpricedTurnCount
                    models[model.id] = existing
                } else {
                    models[model.id] = model
                }
            }
        }

        if combined.lastUpdated == .distantPast {
            combined.lastUpdated = Date()
        }

        combined.perWorkspace = workspaces.values.sorted {
            if $0.costUSD == $1.costUSD { return $0.turnCount > $1.turnCount }
            return $0.costUSD > $1.costUSD
        }
        combined.perModel = models.values.sorted {
            if $0.costUSD == $1.costUSD { return $0.turnCount > $1.turnCount }
            return $0.costUSD > $1.costUSD
        }

        return combined
    }
}

struct UsageAccumulator {
    private(set) var workspaces: [String: WorkspaceUsage] = [:]
    private(set) var models: [String: ModelUsage] = [:]
    private(set) var lastDate: Date = .distantPast
    private(set) var sessionFiles: Set<String> = []

    mutating func registerSession(_ file: URL, workspaceID: String, displayName: String) {
        ensureWorkspace(id: workspaceID, displayName: displayName)
        if sessionFiles.insert(file.path).inserted {
            workspaces[workspaceID]?.sessionCount += 1
        }

        if let modDate = try? file.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate, modDate > lastDate {
            lastDate = modDate
        }
    }

    mutating func addTurn(
        workspaceID: String,
        displayName: String,
        modelID: String,
        input: Int,
        output: Int,
        cacheWrite: Int,
        cacheRead: Int,
        costUSD: Double?
    ) {
        ensureWorkspace(id: workspaceID, displayName: displayName)
        ensureModel(id: modelID)

        let cost = costUSD ?? 0
        let isUnpriced = costUSD == nil

        workspaces[workspaceID]?.inputTokens += input
        workspaces[workspaceID]?.outputTokens += output
        workspaces[workspaceID]?.cacheWriteTokens += cacheWrite
        workspaces[workspaceID]?.cacheReadTokens += cacheRead
        workspaces[workspaceID]?.costUSD += cost
        workspaces[workspaceID]?.turnCount += 1
        if isUnpriced { workspaces[workspaceID]?.unpricedTurnCount += 1 }

        models[modelID]?.costUSD += cost
        models[modelID]?.turnCount += 1
        if isUnpriced { models[modelID]?.unpricedTurnCount += 1 }
    }

    func dailyUsage() -> DailyUsage {
        let allWorkspaces = workspaces.values.sorted {
            if $0.costUSD == $1.costUSD { return $0.turnCount > $1.turnCount }
            return $0.costUSD > $1.costUSD
        }
        let allModels = models.values.sorted {
            if $0.costUSD == $1.costUSD { return $0.turnCount > $1.turnCount }
            return $0.costUSD > $1.costUSD
        }

        return DailyUsage(
            totalCostUSD: allWorkspaces.reduce(0) { $0 + $1.costUSD },
            inputTokens: allWorkspaces.reduce(0) { $0 + $1.inputTokens },
            outputTokens: allWorkspaces.reduce(0) { $0 + $1.outputTokens },
            cacheWriteTokens: allWorkspaces.reduce(0) { $0 + $1.cacheWriteTokens },
            cacheReadTokens: allWorkspaces.reduce(0) { $0 + $1.cacheReadTokens },
            sessionCount: sessionFiles.count,
            turnCount: allWorkspaces.reduce(0) { $0 + $1.turnCount },
            unpricedTurnCount: allWorkspaces.reduce(0) { $0 + $1.unpricedTurnCount },
            lastUpdated: lastDate == .distantPast ? Date() : lastDate,
            perWorkspace: allWorkspaces,
            perModel: allModels
        )
    }

    private mutating func ensureWorkspace(id: String, displayName: String) {
        if workspaces[id] == nil {
            workspaces[id] = WorkspaceUsage(
                id: id,
                displayName: displayName,
                costUSD: 0,
                inputTokens: 0,
                outputTokens: 0,
                cacheWriteTokens: 0,
                cacheReadTokens: 0,
                sessionCount: 0,
                turnCount: 0,
                unpricedTurnCount: 0
            )
        }
    }

    private mutating func ensureModel(id: String) {
        if models[id] == nil {
            models[id] = ModelUsage(id: id, costUSD: 0, turnCount: 0, unpricedTurnCount: 0)
        }
    }
}

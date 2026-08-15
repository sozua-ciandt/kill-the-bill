import Foundation
import CryptoKit

/// Month-to-date budget consumption reported by CI&T's Flow Platform.
/// This is the authoritative, org-configured source of truth when available;
/// local transcript parsing (DailyUsage) remains the fallback and continues
/// to power today's cost, per-project, and per-model breakdowns regardless.
struct FlowBudgetUsage: Sendable, Equatable {
    /// Percentage reported by Flow. This value is only informational because
    /// it is calculated against Flow's own effective limit and can disagree
    /// with the limit source selected by the user.
    var reportedPercentage: Double?
    var consumedUSD: Double
    var limit: Double?
    var budgetLimit: Double?
    var effectiveLimit: Double?
    var individualBudget: Double?
    var limitType: String
    var renewalDate: String
    var status: String
    var fetchedAt: Date

    var isUnlimited: Bool {
        limitType.uppercased() == "NO_LIMIT"
    }

    func resolved(for policy: FlowLimitPolicy) -> ResolvedFlowBudgetUsage {
        let selected = resolvedLimit(for: policy)
        let explicitlyUnlimited = limitType.uppercased() == "NO_LIMIT"
        let isUnavailable = selected == nil && !explicitlyUnlimited
        let percentage: Double

        if let selected {
            percentage = consumedUSD / selected.value * 100
        } else if explicitlyUnlimited || policy == .automatic {
            percentage = reportedPercentage ?? 0
        } else {
            // An explicitly-selected property is not present in this response.
            // Do not reuse Flow's percentage because it belongs to another limit.
            percentage = 0
        }

        return ResolvedFlowBudgetUsage(
            consumedUSD: consumedUSD,
            limit: selected?.value,
            limitSource: selected?.source,
            percentage: percentage,
            isUnlimited: explicitlyUnlimited,
            isLimitUnavailable: isUnavailable,
            renewalDate: renewalDate
        )
    }

    private func resolvedLimit(for policy: FlowLimitPolicy) -> (value: Double, source: FlowLimitPolicy)? {
        guard limitType.uppercased() != "NO_LIMIT" else { return nil }

        switch policy {
        case .automatic:
            if limitType.uppercased() == "INDIVIDUAL",
               let value = individualBudget,
               Self.isUsableLimit(value) {
                return (value, .individual)
            }

            if let value = effectiveLimit, Self.isUsableLimit(value) {
                return (value, .effective)
            }
            if let value = budgetLimit, Self.isUsableLimit(value) {
                return (value, .tenant)
            }
            if let value = limit, Self.isUsableLimit(value) {
                return (value, .tenant)
            }
            if let value = individualBudget, Self.isUsableLimit(value) {
                return (value, .individual)
            }
            return nil

        case .individual:
            guard let value = individualBudget, Self.isUsableLimit(value) else { return nil }
            return (value, .individual)

        case .tenant:
            if let value = budgetLimit, Self.isUsableLimit(value) {
                return (value, .tenant)
            }
            guard let value = limit, Self.isUsableLimit(value) else { return nil }
            return (value, .tenant)

        case .effective:
            guard let value = effectiveLimit, Self.isUsableLimit(value) else { return nil }
            return (value, .effective)
        }
    }

    private static func isUsableLimit(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }
}

struct ResolvedFlowBudgetUsage: Sendable, Equatable {
    let consumedUSD: Double
    let limit: Double?
    let limitSource: FlowLimitPolicy?
    let percentage: Double
    let isUnlimited: Bool
    let isLimitUnavailable: Bool
    let renewalDate: String
}

/// Fetches and caches Flow Platform budget consumption.
///
/// Mirrors the auth flow used by ~/.claude/scripts/flow_budget_query.sh:
/// decode the ANTHROPIC_AUTH_TOKEN JWT payload for clientSecret/tenant,
/// exchange for a Flow access token (cached until near expiry), then query
/// the rate-limit/me budget endpoint. Network calls never block the caller —
/// `currentUsage()` reads the on-disk cache synchronously, and `refresh()`
/// is meant to be awaited from a background Task.
enum FlowBudgetClient {
    private static let authEngineURL = URL(string: "https://flow.ciandt.com/auth-engine-api/v2/api-key/token")!
    private static let consumptionURL = URL(string: "https://flow.ciandt.com/metrics-collector-api/rate-limit/me?mode=budget")!
    private static let requestTimeout: TimeInterval = 5
    private static let tokenExpiryMargin: TimeInterval = 60

    // MARK: - Cache locations

    private static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kill-the-bill/cache")
    }
    private static var budgetCacheFile: URL { cacheDirectory.appendingPathComponent("flow-budget.json") }
    private static var tokenCacheFile: URL { cacheDirectory.appendingPathComponent("flow-token.json") }

    private struct BudgetCacheDTO: Codable {
        let schemaVersion: Int?
        let reportedPercentage: Double?
        /// Kept decode-compatible with the cache written before schema v2.
        let percentage: Double?
        let consumedUSD: Double?
        let limit: Double?
        let budgetLimit: Double?
        let effectiveLimit: Double?
        let individualBudget: Double?
        let limitType: String?
        let renewalDate: String?
        let status: String?
        let fetchedAt: Double?
    }

    private struct TokenCacheDTO: Codable {
        let key: String
        let accessToken: String
        let expiresAt: Double
    }

    struct FlowAuthContext: Equatable {
        let clientSecret: String
        let tenant: String
    }

    // MARK: - Public API

    /// Last known-good budget usage, read straight from disk. Never touches the network.
    static func currentUsage() -> FlowBudgetUsage? {
        guard let data = try? Data(contentsOf: budgetCacheFile),
              let usage = decodeCachedUsage(data) else {
            return nil
        }
        return usage
    }

    static func isStale(
        _ usage: FlowBudgetUsage?,
        ttl: TimeInterval = 60,
        now: Date = Date()
    ) -> Bool {
        guard let usage else { return true }
        let age = now.timeIntervalSince(usage.fetchedAt)
        guard age >= 0 else { return true }
        return age >= max(ttl, 0)
    }

    /// Performs the full auth + fetch flow. Returns nil on any failure (no Flow
    /// token configured, decode failure, network error, non-200 response) — the
    /// caller should keep whatever value it already had rather than clearing it.
    static func refresh() async -> FlowBudgetUsage? {
        guard let token = resolveAuthToken(),
              let context = extractAuthContext(fromJWT: token),
              let accessToken = await resolveAccessToken(context: context),
              let usage = await fetchBudget(accessToken: accessToken) else {
            return nil
        }

        writeCache(usage)
        return usage
    }

    // MARK: - Auth token resolution

    /// GUI apps launched from Finder/login items don't inherit shell-exported
    /// env vars, so fall back to reading the same settings.json Claude Code uses.
    static func resolveAuthToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"], !env.isEmpty {
            return env
        }

        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let token = env["ANTHROPIC_AUTH_TOKEN"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    static func extractAuthContext(fromJWT token: String) -> FlowAuthContext? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payload = base64URLDecode(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let clientSecret = json["clientSecret"] as? String, !clientSecret.isEmpty,
              let tenant = json["tenant"] as? String, !tenant.isEmpty else {
            return nil
        }
        return FlowAuthContext(clientSecret: clientSecret, tenant: tenant)
    }

    private static func base64URLDecode(_ input: String) -> Data? {
        var base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 2: base64 += "=="
        case 3: base64 += "="
        default: break
        }
        return Data(base64Encoded: base64)
    }

    // MARK: - Access token (cached until near expiry)

    private static func resolveAccessToken(context: FlowAuthContext) async -> String? {
        let cacheKey = sha256(context.clientSecret)

        if let cached = readTokenCache(),
           cached.key == cacheKey,
           cached.expiresAt - Date().timeIntervalSince1970 > tokenExpiryMargin {
            return cached.accessToken
        }

        guard let (token, expiresIn) = await requestAccessToken(context: context) else {
            return nil
        }

        let expiresAt = Date().timeIntervalSince1970 + expiresIn
        writeTokenCache(TokenCacheDTO(key: cacheKey, accessToken: token, expiresAt: expiresAt))
        return token
    }

    private static func requestAccessToken(context: FlowAuthContext) async -> (token: String, expiresIn: Double)? {
        var request = URLRequest(url: authEngineURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(context.tenant, forHTTPHeaderField: "FlowTenant")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["clientSecret": context.clientSecret])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            return nil
        }

        let expiresIn = number(json["expires_in"]) ?? 3600
        return (accessToken, expiresIn)
    }

    // MARK: - Budget consumption

    private static func fetchBudget(accessToken: String) async -> FlowBudgetUsage? {
        var request = URLRequest(url: consumptionURL)
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(accessToken, forHTTPHeaderField: "FlowToken")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        return parseBudgetResponse(data)
    }

    /// The response is sometimes wrapped in one or two extra `data` envelopes
    /// depending on the proxy in front of Flow — unwrap defensively.
    static func parseBudgetResponse(_ data: Data, fetchedAt: Date = Date()) -> FlowBudgetUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let inner = unwrapNested(root)
        guard let consumedUSD = number(inner["consumed_usd"]) else { return nil }

        let status = inner["status"] as? String ?? ""
        let renewalDate = inner["renewal_date"] as? String ?? ""
        let limitType = inner["limit_type"] as? String ?? ""

        return FlowBudgetUsage(
            reportedPercentage: number(inner["percentage"]),
            consumedUSD: consumedUSD,
            limit: number(inner["limit"]),
            budgetLimit: number(inner["budget_limit"]),
            effectiveLimit: number(inner["effective_limit"]),
            individualBudget: number(inner["individual_budget"]),
            limitType: limitType,
            renewalDate: renewalDate,
            status: status,
            fetchedAt: fetchedAt
        )
    }

    /// The Flow proxy sometimes adds an extra `{"data": ...}` envelope depending
    /// on how many layers of gateway sit in front of the endpoint, so unwrap
    /// recursively rather than assuming a fixed depth: descend through `data`
    /// wrappers until we reach the object that actually carries `consumed_usd`,
    /// or run out of `data` levels.
    private static func unwrapNested(_ root: [String: Any]) -> [String: Any] {
        var current = root
        while current["consumed_usd"] == nil, let nested = current["data"] as? [String: Any] {
            current = nested
        }
        return current
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let string = any as? String { return Double(string) }
        return nil
    }

    // MARK: - Disk cache I/O

    private static func writeCache(_ usage: FlowBudgetUsage) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let data = encodeCachedUsage(usage) else { return }
        try? data.write(to: budgetCacheFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: budgetCacheFile.path)
    }

    static func decodeCachedUsage(_ data: Data) -> FlowBudgetUsage? {
        guard let dto = try? JSONDecoder().decode(BudgetCacheDTO.self, from: data),
              let consumedUSD = dto.consumedUSD,
              let fetchedAt = dto.fetchedAt else {
            return nil
        }

        return FlowBudgetUsage(
            reportedPercentage: dto.reportedPercentage ?? dto.percentage,
            consumedUSD: consumedUSD,
            limit: dto.limit,
            budgetLimit: dto.budgetLimit,
            effectiveLimit: dto.effectiveLimit,
            individualBudget: dto.individualBudget,
            limitType: dto.limitType ?? "",
            renewalDate: dto.renewalDate ?? "",
            status: dto.status ?? "",
            fetchedAt: Date(timeIntervalSince1970: fetchedAt)
        )
    }

    static func encodeCachedUsage(_ usage: FlowBudgetUsage) -> Data? {
        let dto = BudgetCacheDTO(
            schemaVersion: 2,
            reportedPercentage: usage.reportedPercentage,
            percentage: nil,
            consumedUSD: usage.consumedUSD,
            limit: usage.limit,
            budgetLimit: usage.budgetLimit,
            effectiveLimit: usage.effectiveLimit,
            individualBudget: usage.individualBudget,
            limitType: usage.limitType,
            renewalDate: usage.renewalDate,
            status: usage.status,
            fetchedAt: usage.fetchedAt.timeIntervalSince1970
        )
        return try? JSONEncoder().encode(dto)
    }

    private static func readTokenCache() -> TokenCacheDTO? {
        guard let data = try? Data(contentsOf: tokenCacheFile) else { return nil }
        return try? JSONDecoder().decode(TokenCacheDTO.self, from: data)
    }

    private static func writeTokenCache(_ dto: TokenCacheDTO) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(dto) else { return }
        try? data.write(to: tokenCacheFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenCacheFile.path)
    }

    private static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

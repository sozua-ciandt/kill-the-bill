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

    func resolved(for policy: FlowLimitPolicy, customLimit: Double? = nil) -> ResolvedFlowBudgetUsage {
        let selected = resolvedLimit(for: policy, customLimit: customLimit)
        let explicitlyUnlimited = limitType.uppercased() == "NO_LIMIT"
        let isUnavailable = selected == nil && !explicitlyUnlimited
        let percentage: Double

        if let selected {
            percentage = selected.value > 0 ? (consumedUSD / selected.value * 100) : 0
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

    private func resolvedLimit(
        for policy: FlowLimitPolicy,
        customLimit: Double? = nil
    ) -> (value: Double, source: FlowLimitPolicy)? {
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

        case .custom:
            guard let value = customLimit, Self.isUsableLimit(value) else { return nil }
            return (value, .custom)
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

enum FlowRefreshResult: Sendable, Equatable {
    case success(FlowBudgetUsage)
    case expired
    case failure
    case notConfigured
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
    private static let modelsURL = URL(string: "https://flow.ciandt.com/api/ai-orchestrator/models/by-tenant")!
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

    /// Performs the full auth + fetch flow with an optional preferred API key.
    @discardableResult
    static func refresh(apiKey: String? = nil) async -> FlowRefreshResult {
        guard let token = resolveAuthToken(preferredKey: apiKey) else {
            return .notConfigured
        }

        guard let context = extractAuthContext(fromJWT: token) else {
            return .failure
        }

        let (accessToken, isExpired) = await resolveAccessToken(context: context)
        if isExpired {
            return .expired
        }
        guard let accessToken else {
            return .failure
        }

        var budgetResult = await fetchBudget(accessToken: accessToken)
        if case .expired = budgetResult {
            clearTokenCache()
            let (newAccessToken, reAuthExpired) = await resolveAccessToken(context: context)
            if reAuthExpired {
                return .expired
            }
            if let newAccessToken {
                budgetResult = await fetchBudget(accessToken: newAccessToken)
            }
        }

        switch budgetResult {
        case .success(let usage):
            writeCache(usage)
            async let _ = syncModelsCatalogIfNeeded(accessToken: accessToken)
            return .success(usage)
        case .expired:
            clearTokenCache()
            return .expired
        case .failure:
            return .failure
        }
    }

    /// Convenience wrapper returning usage if successful, nil otherwise.
    static func refresh() async -> FlowBudgetUsage? {
        switch await refresh(apiKey: nil) {
        case .success(let usage): return usage
        default: return nil
        }
    }

    // MARK: - Auth token resolution

    /// GUI apps launched from Finder/login items don't inherit shell-exported
    /// env vars, so fall back to reading the same settings.json Claude Code uses.
    static func resolveInferredAuthToken() -> String? {
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

    /// Resolves the auth token using the preferred key if provided and non-empty,
    /// or falling back to the inferred token from environment or ~/.claude/settings.json.
    static func resolveAuthToken(preferredKey: String? = nil) -> String? {
        if let key = preferredKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        return resolveInferredAuthToken()
    }

    static func isJWTExpired(_ token: String, now: Date = Date()) -> Bool {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payload = base64URLDecode(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return false
        }
        if let exp = number(json["exp"]) {
            return now.timeIntervalSince1970 >= exp
        }
        return false
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

    private enum AccessTokenFetchResult {
        case success(token: String, expiresIn: Double)
        case expired
        case failure
    }

    private static func resolveAccessToken(context: FlowAuthContext) async -> (token: String?, isExpired: Bool) {
        let cacheKey = sha256(context.clientSecret)

        if let cached = readTokenCache(),
           cached.key == cacheKey,
           cached.expiresAt - Date().timeIntervalSince1970 > tokenExpiryMargin {
            return (cached.accessToken, false)
        }

        switch await requestAccessToken(context: context) {
        case .success(let token, let expiresIn):
            let expiresAt = Date().timeIntervalSince1970 + expiresIn
            writeTokenCache(TokenCacheDTO(key: cacheKey, accessToken: token, expiresAt: expiresAt))
            return (token, false)
        case .expired:
            clearTokenCache()
            return (nil, true)
        case .failure:
            return (nil, false)
        }
    }

    private static func requestAccessToken(context: FlowAuthContext) async -> AccessTokenFetchResult {
        var request = URLRequest(url: authEngineURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(context.tenant, forHTTPHeaderField: "FlowTenant")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["clientSecret": context.clientSecret])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            return .expired
        }

        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            return .failure
        }

        let expiresIn = number(json["expires_in"]) ?? 3600
        return .success(token: accessToken, expiresIn: expiresIn)
    }

    // MARK: - Budget consumption

    private enum BudgetFetchResult {
        case success(FlowBudgetUsage)
        case expired
        case failure
    }

    private static func fetchBudget(accessToken: String) async -> BudgetFetchResult {
        var request = URLRequest(url: consumptionURL)
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(accessToken, forHTTPHeaderField: "FlowToken")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            return .expired
        }

        guard http.statusCode == 200,
              let usage = parseBudgetResponse(data) else {
            return .failure
        }

        return .success(usage)
    }

    // MARK: - Models catalog sync

    static func syncModelsCatalogIfNeeded(accessToken: String) async {
        guard FlowPricingCatalog.isCacheStale() else { return }
        if let data = await fetchModelsCatalog(accessToken: accessToken) {
            let pricing = FlowPricingCatalog.decodePricing(from: data)
            if !pricing.isEmpty {
                FlowPricingCatalog.cacheValidatedCatalog(data)
            }
        }
    }

    static func fetchModelsCatalog(accessToken: String) async -> Data? {
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(accessToken, forHTTPHeaderField: "FlowToken")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        return data
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

    static func clearTokenCache() {
        try? FileManager.default.removeItem(at: tokenCacheFile)
    }

    static func clearBudgetCache() {
        try? FileManager.default.removeItem(at: budgetCacheFile)
    }

    private static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

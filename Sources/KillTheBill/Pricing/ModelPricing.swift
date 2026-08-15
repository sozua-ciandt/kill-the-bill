import Foundation

// USD per million tokens.
struct TokenPricing: Equatable, Sendable {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double
}

struct ModelPricing: Sendable {
    private let models: [String: TokenPricing]

    init(models: [String: TokenPricing]) {
        self.models = models
    }

    static func load() -> ModelPricing {
        ModelPricing(models: ModelsDevPricingCatalog.loadPricing())
    }

    func cost(model rawModel: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double? {
        Self.computeCost(
            pricing: Self.lookupPricing(for: rawModel, in: models),
            input: input,
            output: output,
            cacheWrite: cacheWrite,
            cacheRead: cacheRead
        )
    }

    func cost(model rawModel: String, rawInput: Int, output: Int, cachedInput: Int) -> Double? {
        let cacheRead = min(rawInput, cachedInput)
        let nonCachedInput = max(rawInput - cacheRead, 0)

        return cost(
            model: rawModel,
            input: nonCachedInput,
            output: output,
            cacheWrite: 0,
            cacheRead: cacheRead
        )
    }

    static func normalizeProviderModel(_ raw: String) -> String {
        normalizeModel(raw)
    }

    /// Normalizes syntax while retaining a real provider prefix for an exact
    /// catalog lookup. Parsers should use `normalizeModel` for display/grouping.
    static func normalizeQualifiedModel(_ raw: String) -> String {
        var normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Google's SDK uses `models/` as a resource prefix, not a provider ID.
        if normalized.hasPrefix("models/") {
            normalized.removeFirst("models/".count)
        }

        return normalizeCommonModelSyntax(normalized)
    }

    static func normalizeModel(_ raw: String) -> String {
        var normalized = normalizeQualifiedModel(raw)

        for prefix in ["anthropic.", "openai."] where normalized.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
        }

        let knownProviderPrefixes = [
            "anthropic/", "openai/", "google/", "xai/", "mistral/",
            "cohere/", "deepseek/", "alibaba/",
        ]
        for prefix in knownProviderPrefixes where normalized.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
            break
        }

        return normalized
    }

    private static func lookupPricing(
        for rawModel: String,
        in models: [String: TokenPricing]
    ) -> TokenPricing? {
        let providerQualified = normalizeQualifiedModel(rawModel)
        if let exact = models[providerQualified] {
            return exact
        }
        return models[normalizeModel(rawModel)]
    }

    private static func normalizeCommonModelSyntax(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "gpt-5-5", with: "gpt-5.5")
            .replacingOccurrences(of: "gpt-5-4", with: "gpt-5.4")
            .replacing(#/-\d{8}$/#, with: "")
    }

    private static func computeCost(pricing: TokenPricing?, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double? {
        guard let pricing else { return nil }

        let million = 1_000_000.0
        return (Double(input) / million * pricing.input)
            + (Double(output) / million * pricing.output)
            + (Double(cacheWrite) / million * pricing.cacheWrite)
            + (Double(cacheRead) / million * pricing.cacheRead)
    }
}

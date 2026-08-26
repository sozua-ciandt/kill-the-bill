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
        var models = ModelsDevPricingCatalog.loadPricing()
        let flowPricing = FlowPricingCatalog.loadPricing()
        for (key, pricing) in flowPricing {
            models[key] = pricing
        }
        return ModelPricing(models: models)
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

        while true {
            var changed = false
            if normalized.hasPrefix("flow-"),
               let slashIndex = normalized.firstIndex(of: "/") {
                normalized.removeSubrange(normalized.startIndex...slashIndex)
                changed = true
            }

            let knownProviderPrefixes = [
                "flow/", "azure-foundry/", "azure-openai/", "google-gemini/",
                "amazon-bedrock/", "azure-ai-speech/", "anthropic/", "openai/",
                "google/", "xai/", "mistral/", "cohere/", "deepseek/", "alibaba/",
                "openrouter/", "anthropic.", "openai."
            ]
            for prefix in knownProviderPrefixes where normalized.hasPrefix(prefix) {
                normalized.removeFirst(prefix.count)
                changed = true
                break
            }

            if !changed { break }
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
        let normalized = normalizeModel(rawModel)
        if let match = models[normalized] {
            return match
        }
        if let match = models["anthropic.\(normalized)"] {
            return match
        }
        if let match = models["openai.\(normalized)"] {
            return match
        }
        return nil
    }

    private static func normalizeCommonModelSyntax(_ raw: String) -> String {
        raw
            .replacing(#/\[\d+[a-zA-Z0-9_-]*\]/#, with: "")
            .replacing(#/gpt-5-([0-9])/#, with: { "gpt-5.\($0.1)" })
            .replacing(#/gpt-4-([0-9])/#, with: { "gpt-4.\($0.1)" })
            .replacing(#/gpt-3-([0-9])/#, with: { "gpt-3.\($0.1)" })
            .replacingOccurrences(of: "gpt-5-5", with: "gpt-5.5")
            .replacingOccurrences(of: "gpt-5-4", with: "gpt-5.4")
            .replacing(#/-\d{8}$/#, with: "")
            .replacing(#/-\d{4}$/#, with: "")
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

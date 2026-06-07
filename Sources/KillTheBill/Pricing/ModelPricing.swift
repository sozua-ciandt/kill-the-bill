import Foundation

// USD per million tokens.
struct TokenPricing: Sendable {
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

    static func load(customProviders: [CustomProviderConfig] = CustomProviderLoader.loadProviders()) -> ModelPricing {
        var models = ModelsDevPricingCatalog.loadPricing()
        let customPricing = CustomProviderLoader.loadCustomPricing(from: customProviders)
        models.merge(customPricing) { _, custom in custom }

        return ModelPricing(models: models)
    }

    func cost(model rawModel: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double? {
        Self.computeCost(
            pricing: models[Self.normalizeModel(rawModel)],
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

    static func normalizeModel(_ raw: String) -> String {
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: "anthropic.", with: "")
            .replacingOccurrences(of: "openai/", with: "")
            .replacingOccurrences(of: "openai.", with: "")
            .replacingOccurrences(of: "gpt-5-5", with: "gpt-5.5")
            .replacingOccurrences(of: "gpt-5-4", with: "gpt-5.4")
            .replacingOccurrences(of: "models/", with: "")
            .replacing(#/-\d{8}$/#, with: "")

        return normalized
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

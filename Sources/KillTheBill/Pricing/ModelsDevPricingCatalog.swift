import Foundation

private struct ModelsDevProvider: Decodable {
    let id: String
    let models: [String: ModelsDevModel]
}

private struct ModelsDevModel: Decodable {
    let id: String
    let cost: ModelsDevCost?
}

private struct ModelsDevCost: Decodable {
    let input: Double?
    let output: Double?
    let cache_read: Double?
    let cache_write: Double?
}

enum ModelsDevPricingCatalog {
    private static let catalogURL = URL(string: "https://models.dev/api.json")!
    private static let cacheMaxAge: TimeInterval = 24 * 60 * 60

    static func loadPricing() -> [String: TokenPricing] {
        guard let data = cachedCatalogData(maxAge: cacheMaxAge) ?? remoteCatalogData() ?? cachedCatalogData() else {
            return [:]
        }

        return decodePricing(from: data)
    }

    static func decodePricing(from data: Data) -> [String: TokenPricing] {
        guard let providers = try? JSONDecoder().decode([String: ModelsDevProvider].self, from: data) else {
            return [:]
        }

        var pricing: [String: TokenPricing] = [:]

        for (providerKey, provider) in providers {
            for (modelKey, model) in provider.models {
                guard let cost = model.cost,
                      let input = cost.input,
                      let output = cost.output else {
                    continue
                }

                let tokenPricing = TokenPricing(
                    input: input,
                    output: output,
                    cacheWrite: cost.cache_write ?? 0,
                    cacheRead: cost.cache_read ?? input
                )

                let providerIDs = Set([providerKey, provider.id])
                let modelIDs = Set([modelKey, model.id])

                for modelID in modelIDs {
                    pricing[ModelPricing.normalizeProviderModel(modelID)] = tokenPricing

                    for providerID in providerIDs {
                        pricing[ModelPricing.normalizeProviderModel("\(providerID)/\(modelID)")] = tokenPricing
                    }
                }
            }
        }

        return pricing
    }

    private static func cachedCatalogData(maxAge: TimeInterval? = nil) -> Data? {
        let file = cacheFile
        if let maxAge {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  Date().timeIntervalSince(modifiedAt) < maxAge else {
                return nil
            }
        }

        return try? Data(contentsOf: file)
    }

    private static func remoteCatalogData() -> Data? {
        guard let data = try? Data(contentsOf: catalogURL) else {
            return nil
        }

        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheFile)

        return data
    }

    private static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kill-the-bill/cache")
    }

    private static var cacheFile: URL {
        cacheDirectory.appendingPathComponent("models-dev-api.json")
    }
}

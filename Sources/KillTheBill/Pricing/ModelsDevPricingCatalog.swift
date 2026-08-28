import Foundation

private struct ModelsDevProvider: Decodable {
    let id: String?
    let models: [String: ModelsDevModel]?
}

private struct ModelsDevModel: Decodable {
    let id: String?
    let base_model: String?
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

    private struct PricingCandidate {
        let providerKey: String
        let providerIDs: [String]
        let modelID: String
        let preferredProvider: String?
        let pricing: TokenPricing

        var preferenceRank: Int {
            guard let preferredProvider else { return 1 }
            return providerIDs.contains(preferredProvider) ? 0 : 1
        }
    }

    private static func fallbackPricing() -> [String: TokenPricing] {
        return [
            "claude-4-5-haiku": TokenPricing(input: 0.25, output: 1.25, cacheWrite: 0, cacheRead: 0.25),
            "claude-haiku-4-5": TokenPricing(input: 0.25, output: 1.25, cacheWrite: 0, cacheRead: 0.25),
            "claude-5-sonnet": TokenPricing(input: 3.0, output: 15.0, cacheWrite: 0, cacheRead: 3.0),
            "claude-sonnet-5": TokenPricing(input: 3.0, output: 15.0, cacheWrite: 0, cacheRead: 3.0),
            "gemini-3.7-flash": TokenPricing(input: 0.35, output: 0.70, cacheWrite: 0, cacheRead: 0.35),
            "gpt-5.6-luna": TokenPricing(input: 0.50, output: 1.50, cacheWrite: 0, cacheRead: 0.50)
        ]
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheFile)
    }

    static func loadPricing(forceReload: Bool = false) -> [String: TokenPricing] {
        if !forceReload,
           let data = cachedCatalogData(maxAge: cacheMaxAge),
           let pricing = decodedPricing(from: data) {
            return pricing
        }

        if let data = remoteCatalogData(),
           let pricing = decodedPricing(from: data) {
            cacheValidatedCatalog(data)
            return pricing
        }

        if let data = cachedCatalogData(),
           let pricing = decodedPricing(from: data) {
            return pricing
        }

        return fallbackPricing()
    }

    static func decodePricing(from data: Data) -> [String: TokenPricing] {
        decodedPricing(from: data) ?? [:]
    }

    private static func decodedPricing(from data: Data) -> [String: TokenPricing]? {
        guard let providers = try? JSONDecoder().decode([String: ModelsDevProvider].self, from: data),
              !providers.isEmpty else {
            return nil
        }

        var pricing: [String: TokenPricing] = [:]
        var candidatesByUnqualifiedID: [String: [PricingCandidate]] = [:]

        for providerKey in providers.keys.sorted() {
            guard let provider = providers[providerKey] else { continue }
            var providerIDSet = Set([providerKey.lowercased()])
            if let providerID = provider.id?.lowercased(), !providerID.isEmpty {
                providerIDSet.insert(providerID)
            }
            let providerIDs = providerIDSet.sorted()

            for modelKey in (provider.models ?? [:]).keys.sorted() {
                guard let model = provider.models?[modelKey],
                      let cost = model.cost,
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
                var modelIDSet = Set([modelKey])
                if let modelID = model.id, !modelID.isEmpty {
                    modelIDSet.insert(modelID)
                }
                let modelIDs = modelIDSet.sorted()
                let preferred = preferredProvider(
                    for: modelIDs.first ?? modelKey,
                    baseModel: model.base_model
                )

                for modelID in modelIDs {
                    let normalizedModelID = ModelPricing.normalizeQualifiedModel(modelID)
                    guard !normalizedModelID.isEmpty else { continue }

                    // Preserve the provider when the transcript records one.
                    for providerID in providerIDs {
                        let qualified = ModelPricing.normalizeQualifiedModel(
                            "\(providerID)/\(normalizedModelID)"
                        )
                        if pricing[qualified] == nil {
                            pricing[qualified] = tokenPricing
                        }
                    }

                    var aliases = Set([ModelPricing.normalizeModel(modelID)])
                    if let baseModel = model.base_model {
                        aliases.insert(ModelPricing.normalizeModel(baseModel))
                    }
                    aliases.remove("")

                    for alias in aliases {
                        candidatesByUnqualifiedID[alias, default: []].append(
                            PricingCandidate(
                                providerKey: providerKey.lowercased(),
                                providerIDs: providerIDs,
                                modelID: normalizedModelID,
                                preferredProvider: preferred,
                                pricing: tokenPricing
                            )
                        )
                    }
                }
            }
        }

        // Unqualified transcript IDs are resolved only after every provider has
        // been considered. The model's direct vendor wins; ties are lexical so
        // JSON object order can never change the selected price.
        for alias in candidatesByUnqualifiedID.keys.sorted() {
            let candidates = candidatesByUnqualifiedID[alias, default: []].sorted {
                if $0.preferenceRank != $1.preferenceRank {
                    return $0.preferenceRank < $1.preferenceRank
                }
                if $0.providerKey != $1.providerKey {
                    return $0.providerKey < $1.providerKey
                }
                return $0.modelID < $1.modelID
            }
            if let selected = candidates.first {
                pricing[alias] = selected.pricing
            }
        }

        return pricing
    }

    private static func preferredProvider(for modelID: String, baseModel: String?) -> String? {
        if let baseModel {
            let components = baseModel.split(separator: "/", maxSplits: 1)
            if components.count == 2, let provider = components.first, !provider.isEmpty {
                return String(provider).lowercased()
            }
        }

        let normalized = ModelPricing.normalizeModel(baseModel ?? modelID)
        if normalized.hasPrefix("claude-") { return "anthropic" }
        if normalized.hasPrefix("gpt-") || normalized.hasPrefix("chatgpt-") ||
            normalized.hasPrefix("codex-") ||
            normalized.range(of: #"^o\d"#, options: .regularExpression) != nil {
            return "openai"
        }
        if normalized.hasPrefix("gemini-") { return "google" }
        if normalized.hasPrefix("grok-") { return "xai" }
        if normalized.hasPrefix("mistral-") || normalized.hasPrefix("codestral-") ||
            normalized.hasPrefix("pixtral-") {
            return "mistral"
        }
        if normalized.hasPrefix("command-") { return "cohere" }
        if normalized.hasPrefix("deepseek-") { return "deepseek" }
        if normalized.hasPrefix("qwen") { return "alibaba" }
        return nil
    }

    private static func cachedCatalogData(maxAge: TimeInterval? = nil) -> Data? {
        let file = cacheFile
        if let maxAge {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  Date().timeIntervalSince(modifiedAt) >= 0,
                  Date().timeIntervalSince(modifiedAt) < maxAge else {
                return nil
            }
        }

        return try? Data(contentsOf: file)
    }

    private static func remoteCatalogData() -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5.0
        configuration.timeoutIntervalForResource = 5.0
        let session = URLSession(configuration: configuration)
        nonisolated(unsafe) var result: Data?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: catalogURL) { data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = data
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5.0)
        return result
    }

    private static func cacheValidatedCatalog(_ data: Data) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }

    private static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kill-the-bill/cache")
    }

    private static var cacheFile: URL {
        cacheDirectory.appendingPathComponent("models-dev-api.json")
    }
}

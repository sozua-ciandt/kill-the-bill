import Foundation

private struct FlowModelsResponse: Decodable {
    let data: FlowModelsDataWrapper?
    let enabledModels: [FlowModelItem]?
    let disabledModels: [FlowModelItem]?

    var allModels: [FlowModelItem] {
        var list: [FlowModelItem] = []
        if let models = enabledModels { list.append(contentsOf: models) }
        if let models = disabledModels { list.append(contentsOf: models) }
        if let wrapper = data {
            list.append(contentsOf: wrapper.allModels)
        }
        return list
    }
}

private struct FlowModelsDataWrapper: Decodable {
    let data: FlowModelsData?
    let enabledModels: [FlowModelItem]?
    let disabledModels: [FlowModelItem]?

    var allModels: [FlowModelItem] {
        var list: [FlowModelItem] = []
        if let models = enabledModels { list.append(contentsOf: models) }
        if let models = disabledModels { list.append(contentsOf: models) }
        if let inner = data {
            list.append(contentsOf: inner.allModels)
        }
        return list
    }
}

private struct FlowModelsData: Decodable {
    let enabledModels: [FlowModelItem]?
    let disabledModels: [FlowModelItem]?

    var allModels: [FlowModelItem] {
        var list: [FlowModelItem] = []
        if let models = enabledModels { list.append(contentsOf: models) }
        if let models = disabledModels { list.append(contentsOf: models) }
        return list
    }
}

struct FlowModelItem: Decodable, Sendable {
    let name: String?
    let modelName: String?
    let id: String?
    let vendor: String?
    let provider: String?
    let inputCostPerMillionToken: Double?
    let outputCostPerMillionToken: Double?
    let inputTokenCost: Double?
    let outputTokenCost: Double?
    let cacheReadTokenCost: Double?
    let cacheCreation5mTokenCost: Double?
    let cacheCreation1hTokenCost: Double?
    let aliases: [String]?

    var resolvedName: String? {
        name ?? modelName ?? id
    }

    var tokenPricing: TokenPricing {
        let input = inputCostPerMillionToken ?? ((inputTokenCost ?? 0) * 1_000_000)
        let output = outputCostPerMillionToken ?? ((outputTokenCost ?? 0) * 1_000_000)
        let cacheRead = (cacheReadTokenCost ?? 0) * 1_000_000
        let cacheWrite = ((cacheCreation5mTokenCost ?? cacheCreation1hTokenCost) ?? 0) * 1_000_000

        return TokenPricing(
            input: input,
            output: output,
            cacheWrite: cacheWrite,
            cacheRead: cacheRead
        )
    }
}

enum FlowPricingCatalog {
    static let cacheMaxAge: TimeInterval = 24 * 60 * 60

    static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kill-the-bill/cache")
    }

    static var cacheFile: URL {
        cacheDirectory.appendingPathComponent("flow-models.json")
    }

    static func isCacheStale(now: Date = Date(), maxAge: TimeInterval = cacheMaxAge) -> Bool {
        guard let values = try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate else {
            return true
        }
        let age = now.timeIntervalSince(modifiedAt)
        return age < 0 || age >= maxAge
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheFile)
    }

    static func loadPricing(forceReload: Bool = false) -> [String: TokenPricing] {
        if !forceReload,
           let data = cachedCatalogData(maxAge: cacheMaxAge),
           let pricing = decodedPricing(from: data),
           !pricing.isEmpty {
            return pricing
        }

        if let data = cachedCatalogData(),
           let pricing = decodedPricing(from: data),
           !pricing.isEmpty {
            return pricing
        }

        return fallbackPricing()
    }

    static func decodePricing(from data: Data) -> [String: TokenPricing] {
        decodedPricing(from: data) ?? [:]
    }

    static func cacheValidatedCatalog(_ data: Data) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
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

    private static func decodedPricing(from data: Data) -> [String: TokenPricing]? {
        var items: [FlowModelItem] = []

        if let response = try? JSONDecoder().decode(FlowModelsResponse.self, from: data) {
            items = response.allModels
        } else if let array = try? JSONDecoder().decode([FlowModelItem].self, from: data) {
            items = array
        } else if let wrapper = try? JSONDecoder().decode(FlowModelsDataWrapper.self, from: data) {
            items = wrapper.allModels
        } else if let dataObj = try? JSONDecoder().decode(FlowModelsData.self, from: data) {
            items = dataObj.allModels
        }

        guard !items.isEmpty else { return nil }

        var pricing: [String: TokenPricing] = [:]
        for item in items {
            guard let rawName = item.resolvedName, !rawName.isEmpty else { continue }
            let tokenPricing = item.tokenPricing
            let aliases = generateAliases(for: item)
            for alias in aliases {
                pricing[alias] = tokenPricing
            }
        }

        return pricing.isEmpty ? nil : pricing
    }

    static func generateAliases(for item: FlowModelItem) -> Set<String> {
        guard let rawName = item.resolvedName, !rawName.isEmpty else { return [] }

        var aliases = Set<String>()
        let normalized = ModelPricing.normalizeModel(rawName)
        let qualifiedRaw = ModelPricing.normalizeQualifiedModel(rawName)

        if !normalized.isEmpty {
            aliases.insert(normalized)
            aliases.insert("flow/\(normalized)")
        }
        if !qualifiedRaw.isEmpty {
            aliases.insert(qualifiedRaw)
            aliases.insert("flow/\(qualifiedRaw)")
        }

        var vendors = Set<String>()
        if let vendor = item.vendor?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !vendor.isEmpty {
            vendors.insert(vendor)
        }
        if let provider = item.provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !provider.isEmpty {
            vendors.insert(provider)
        }

        let inferredProviders = inferProviders(for: normalized)
        for p in inferredProviders {
            vendors.insert(p)
        }

        for vendor in vendors {
            if !normalized.isEmpty {
                aliases.insert("\(vendor)/\(normalized)")
                aliases.insert("flow-\(vendor)/\(normalized)")
                aliases.insert("\(vendor).\(normalized)")
            }
            if !qualifiedRaw.isEmpty && qualifiedRaw != normalized {
                aliases.insert("\(vendor)/\(qualifiedRaw)")
                aliases.insert("flow-\(vendor)/\(qualifiedRaw)")
                aliases.insert("\(vendor).\(qualifiedRaw)")
            }
        }

        // Add hyphenated variation aliases (e.g. claude-sonnet-5 <-> claude-5-sonnet, claude-haiku-4-5 <-> claude-4-5-haiku)
        if normalized.hasPrefix("claude-") {
            let parts = normalized.split(separator: "-").map(String.init)
            if parts.count >= 3 {
                if parts[1] == "sonnet" || parts[1] == "haiku" || parts[1] == "opus" {
                    let family = parts[1]
                    let version = parts[2...].joined(separator: "-")
                    let flipped = "claude-\(version)-\(family)"
                    aliases.insert(flipped)
                    aliases.insert("flow/\(flipped)")
                    for vendor in vendors {
                        aliases.insert("\(vendor)/\(flipped)")
                        aliases.insert("flow-\(vendor)/\(flipped)")
                        aliases.insert("\(vendor).\(flipped)")
                    }
                } else if parts.last == "sonnet" || parts.last == "haiku" || parts.last == "opus" {
                    let family = parts.last!
                    let version = parts[1..<(parts.count - 1)].joined(separator: "-")
                    let flipped = "claude-\(family)-\(version)"
                    aliases.insert(flipped)
                    aliases.insert("flow/\(flipped)")
                    for vendor in vendors {
                        aliases.insert("\(vendor)/\(flipped)")
                        aliases.insert("flow-\(vendor)/\(flipped)")
                        aliases.insert("\(vendor).\(flipped)")
                    }
                }
            }
        }

        if let explicitAliases = item.aliases {
            for alias in explicitAliases {
                let normAlias = ModelPricing.normalizeModel(alias)
                let qualAlias = ModelPricing.normalizeQualifiedModel(alias)
                if !normAlias.isEmpty {
                    aliases.insert(normAlias)
                    aliases.insert("flow/\(normAlias)")
                    for vendor in vendors {
                        aliases.insert("\(vendor)/\(normAlias)")
                        aliases.insert("flow-\(vendor)/\(normAlias)")
                    }
                }
                if !qualAlias.isEmpty {
                    aliases.insert(qualAlias)
                    aliases.insert("flow/\(qualAlias)")
                }
            }
        }

        return aliases
    }

    private static func inferProviders(for normalizedModel: String) -> [String] {
        var providers: [String] = []
        if normalizedModel.hasPrefix("claude-") {
            providers.append("anthropic")
        } else if normalizedModel.hasPrefix("gpt-") || normalizedModel.hasPrefix("chatgpt-") ||
                    normalizedModel.hasPrefix("codex-") ||
                    normalizedModel.range(of: #"^o\d"#, options: .regularExpression) != nil {
            providers.append("openai")
            providers.append("azure-openai")
        } else if normalizedModel.hasPrefix("gemini-") {
            providers.append("gemini")
            providers.append("google")
            providers.append("google-gemini")
        } else if normalizedModel.hasPrefix("deepseek-") {
            providers.append("deepseek")
            providers.append("azure-foundry")
        } else if normalizedModel.hasPrefix("llama-") {
            providers.append("meta")
            providers.append("azure-foundry")
        } else if normalizedModel.hasPrefix("mistral-") || normalizedModel.hasPrefix("codestral-") ||
                    normalizedModel.hasPrefix("pixtral-") {
            providers.append("mistral")
            providers.append("azure-foundry")
        } else if normalizedModel.hasPrefix("command-") {
            providers.append("cohere")
            providers.append("amazon-bedrock")
        } else if normalizedModel.hasPrefix("qwen") {
            providers.append("alibaba")
            providers.append("qwen")
        }
        return providers
    }

    static func fallbackPricing() -> [String: TokenPricing] {
        var pricing: [String: TokenPricing] = [:]

        // Reference 52 corporate models for Flow with alias generation
        let referenceModels: [(name: String, vendor: String?, input: Double, output: Double, cacheRead: Double, cacheWrite: Double)] = [
            // DeepSeek
            ("DeepSeek-V4-Pro", "azure-foundry", 1.74, 3.48, 0.174, 0.348),
            ("DeepSeek-V4-Flash", "azure-foundry", 0.25, 0.50, 0.025, 0.05),
            ("deepseek-v4", "azure-foundry", 0.50, 1.50, 0.05, 0.10),
            ("deepseek-chat", "deepseek", 0.14, 0.28, 0.014, 0.028),
            ("deepseek-coder", "deepseek", 0.14, 0.28, 0.014, 0.028),
            ("deepseek-v3", "deepseek", 0.14, 0.28, 0.014, 0.028),
            ("deepseek-r1", "deepseek", 0.55, 2.19, 0.055, 0.11),

            // Google Gemini
            ("gemini-3.7-flash", "google", 0.75, 3.75, 0.075, 0.15),
            ("gemini-3.7-pro", "google", 1.50, 6.00, 0.375, 0.75),
            ("gemini-2.5-pro", "google", 1.25, 10.00, 0.3125, 0.625),
            ("gemini-2.5-flash", "google", 0.15, 0.60, 0.0375, 0.075),
            ("gemini-2.0-flash", "google", 0.10, 0.40, 0.025, 0.05),
            ("gemini-2.0-pro", "google", 1.25, 5.00, 0.3125, 0.625),
            ("gemini-1.5-pro", "google", 1.25, 5.00, 0.3125, 0.625),
            ("gemini-1.5-flash", "google", 0.075, 0.30, 0.01875, 0.0375),

            // OpenAI & Codex
            ("gpt-5.1-codex", "openai", 1.25, 10.00, 0.125, 0.25),
            ("gpt-5.6-sol", "openai", 2.50, 10.00, 0.25, 0.50),
            ("gpt-5.6-luna", "openai", 0.50, 1.50, 0.05, 0.10),
            ("gpt-5", "openai", 5.00, 20.00, 0.50, 1.00),
            ("gpt-5.1", "openai", 5.00, 20.00, 0.50, 1.00),
            ("gpt-5.2", "openai", 5.00, 20.00, 0.50, 1.00),
            ("gpt-5.4", "openai", 5.00, 20.00, 0.50, 1.00),
            ("gpt-5.5", "openai", 5.00, 20.00, 0.50, 1.00),
            ("gpt-4o", "openai", 2.50, 10.00, 1.25, 2.50),
            ("gpt-4o-mini", "openai", 0.15, 0.60, 0.075, 0.15),
            ("gpt-4-turbo", "openai", 10.00, 30.00, 5.00, 10.00),
            ("gpt-4", "openai", 30.00, 60.00, 15.00, 30.00),
            ("gpt-3.5-turbo", "openai", 0.50, 1.50, 0.25, 0.50),
            ("o1", "openai", 15.00, 60.00, 7.50, 15.00),
            ("o1-mini", "openai", 3.00, 12.00, 1.50, 3.00),
            ("o1-preview", "openai", 15.00, 60.00, 7.50, 15.00),
            ("o3", "openai", 15.00, 60.00, 7.50, 15.00),
            ("o3-mini", "openai", 1.10, 4.40, 0.55, 1.10),

            // Anthropic Claude
            ("claude-sonnet-5", "anthropic", 3.00, 15.00, 0.30, 3.75),
            ("claude-haiku-4-5", "anthropic", 0.25, 1.25, 0.025, 0.30),
            ("claude-opus-4-8", "anthropic", 15.00, 75.00, 1.50, 18.75),
            ("claude-sonnet-4-6", "anthropic", 3.00, 15.00, 0.30, 3.75),
            ("claude-opus-4-6", "anthropic", 15.00, 75.00, 1.50, 18.75),
            ("claude-haiku-4-6", "anthropic", 0.25, 1.25, 0.025, 0.30),
            ("claude-3-7-sonnet", "anthropic", 3.00, 15.00, 0.30, 3.75),
            ("claude-3-5-sonnet", "anthropic", 3.00, 15.00, 0.30, 3.75),
            ("claude-3-5-haiku", "anthropic", 0.80, 4.00, 0.08, 1.00),
            ("claude-3-opus", "anthropic", 15.00, 75.00, 1.50, 18.75),
            ("claude-3-haiku", "anthropic", 0.25, 1.25, 0.025, 0.30),

            // Meta LLaMA
            ("llama-3.1-8b", "azure-foundry", 0.05, 0.10, 0.01, 0.02),
            ("llama-3.1-70b", "azure-foundry", 0.40, 0.80, 0.08, 0.16),
            ("llama-3.1-405b", "azure-foundry", 2.00, 4.00, 0.40, 0.80),
            ("llama-3.2-3b", "azure-foundry", 0.03, 0.06, 0.006, 0.012),
            ("llama-3.3-70b", "azure-foundry", 0.40, 0.80, 0.08, 0.16),

            // Mistral AI
            ("mistral-large", "azure-foundry", 2.00, 6.00, 0.50, 1.00),
            ("mistral-small", "azure-foundry", 0.20, 0.60, 0.05, 0.10),
            ("codestral", "azure-foundry", 0.30, 0.90, 0.075, 0.15),
            ("pixtral", "azure-foundry", 0.30, 0.90, 0.075, 0.15),

            // Cohere & Qwen
            ("command-r", "cohere", 0.15, 0.60, 0.0375, 0.075),
            ("command-r-plus", "cohere", 2.50, 10.00, 0.625, 1.25),
            ("qwen-2.5-coder-32b", "alibaba", 0.20, 0.60, 0.05, 0.10),
        ]

        for model in referenceModels {
            let item = FlowModelItem(
                name: model.name,
                modelName: nil,
                id: nil,
                vendor: model.vendor,
                provider: nil,
                inputCostPerMillionToken: model.input,
                outputCostPerMillionToken: model.output,
                inputTokenCost: nil,
                outputTokenCost: nil,
                cacheReadTokenCost: model.cacheRead / 1_000_000,
                cacheCreation5mTokenCost: model.cacheWrite / 1_000_000,
                cacheCreation1hTokenCost: nil,
                aliases: nil
            )
            let tokenPricing = item.tokenPricing
            let aliases = generateAliases(for: item)
            for alias in aliases {
                pricing[alias] = tokenPricing
            }
        }

        return pricing
    }
}

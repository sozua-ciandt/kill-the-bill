import Foundation

struct CustomProviderConfig: Decodable, Hashable, Sendable {
    let id: String
    let name: String?
    let files: CustomProviderFiles?
    let event: CustomProviderEvent?
    let pricing: [CustomProviderModelPricing]?
}

struct CustomProviderFiles: Decodable, Hashable, Sendable {
    let roots: [String]
    let recursive: Bool?
    let extensions: [String]?
}

struct CustomProviderEvent: Decodable, Hashable, Sendable {
    let matches: [CustomProviderMatch]?
    let workspacePath: [String]?
    let workspaceDefault: String?
    let modelPath: [String]?
    let modelDefault: String?
    let inputTokensPath: [String]?
    let outputTokensPath: [String]?
    let cacheReadTokensPath: [String]?
    let cacheWriteTokensPath: [String]?
    let totalTokensPath: [String]?
}

struct CustomProviderMatch: Decodable, Hashable, Sendable {
    let path: [String]
    let equals: String
}

struct CustomProviderModelPricing: Decodable, Hashable, Sendable {
    let model: String
    let aliases: [String]?
    let input: Double
    let output: Double
    let cacheWrite: Double?
    let cacheRead: Double?
}

enum CustomProviderLoader {
    static var providerDirectory: URL {
        if let customPath = ProcessInfo.processInfo.environment["KILL_THE_BILL_PROVIDER_DIR"], !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kill-the-bill/providers")
    }

    static func loadProviders() -> [CustomProviderConfig] {
        try? FileManager.default.createDirectory(
            at: providerDirectory,
            withIntermediateDirectories: true
        )

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: providerDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true,
                      let data = try? Data(contentsOf: file) else {
                    return nil
                }
                return try? decoder.decode(CustomProviderConfig.self, from: data)
            }
    }

    static func loadCustomPricing(from providers: [CustomProviderConfig]) -> [String: TokenPricing] {
        var pricing: [String: TokenPricing] = [:]

        for provider in providers {
            for model in provider.pricing ?? [] {
                let modelPricing = TokenPricing(
                    input: model.input,
                    output: model.output,
                    cacheWrite: model.cacheWrite ?? 0,
                    cacheRead: model.cacheRead ?? model.input
                )
                let keys = [model.model] + (model.aliases ?? [])
                for key in keys {
                    pricing[ModelPricing.normalizeProviderModel(key)] = modelPricing
                }
            }
        }

        return pricing
    }
}

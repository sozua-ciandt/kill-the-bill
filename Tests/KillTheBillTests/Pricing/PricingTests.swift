import Foundation
import XCTest
@testable import KillTheBill

final class PricingTests: XCTestCase {
    func testCostUsesExactModelPricing() {
        let pricing = ModelPricing(models: [
            "test-model": TokenPricing(input: 2, output: 8, cacheWrite: 3, cacheRead: 1)
        ])

        let cost = pricing.cost(
            model: "test-model",
            input: 1_000_000,
            output: 500_000,
            cacheWrite: 100_000,
            cacheRead: 200_000
        )

        XCTAssertNotNil(cost)
        assertDoubleEqual(cost!, 6.5)
    }

    func testRawInputCostSeparatesCachedInput() {
        let pricing = ModelPricing(models: [
            "gpt-5.5": TokenPricing(input: 5, output: 30, cacheWrite: 0, cacheRead: 0.5)
        ])

        let cost = pricing.cost(
            model: "openai/gpt-5-5",
            rawInput: 1_000_000,
            output: 100_000,
            cachedInput: 250_000
        )

        XCTAssertNotNil(cost)
        assertDoubleEqual(cost!, 6.875)
    }

    func testUnknownModelHasNoCost() {
        XCTAssertNil(testPricing().cost(model: "missing", input: 1, output: 1, cacheWrite: 0, cacheRead: 0))
    }

    func testModelNormalizationHandlesCommonProviderPrefixesAndDateSuffixes() {
        XCTAssertEqual(ModelPricing.normalizeModel("anthropic.claude-sonnet-4-5-20250929"), "claude-sonnet-4-5")
        XCTAssertEqual(ModelPricing.normalizeModel("openai/gpt-5-5"), "gpt-5.5")
        XCTAssertEqual(ModelPricing.normalizeModel("models/gemini-2.5-pro"), "gemini-2.5-pro")
        XCTAssertEqual(ModelPricing.normalizeProviderModel("openai/gpt-5-5"), "gpt-5.5")
        XCTAssertEqual(ModelPricing.normalizeQualifiedModel("openai/gpt-5-5"), "openai/gpt-5.5")
    }

    func testModelsDevCatalogDecodesProviderQualifiedAliases() {
        let json = """
        {
          "google": {
            "id": "google",
            "models": {
              "gemini-2.5-pro": {
                "id": "gemini-2.5-pro",
                "cost": { "input": 1.25, "output": 10, "cache_read": 0.125 }
              }
            }
          }
        }
        """

        let pricing = ModelsDevPricingCatalog.decodePricing(from: Data(json.utf8))

        assertDoubleEqual(pricing["gemini-2.5-pro"]?.input ?? -1, 1.25)
        assertDoubleEqual(pricing["google/gemini-2.5-pro"]?.output ?? -1, 10)
        assertDoubleEqual(pricing["google/gemini-2.5-pro"]?.cacheRead ?? -1, 0.125)
    }

    func testOfficialProviderDeterministicallyWinsUnqualifiedAlias() {
        let providersFirst = """
        {
          "unorouter": {"id":"unorouter","models":{"claude-sonnet-5":{
            "id":"claude-sonnet-5","base_model":"anthropic/claude-sonnet-5",
            "cost":{"input":1.44,"output":7.2}}}},
          "anthropic": {"id":"anthropic","models":{"claude-sonnet-5":{
            "id":"claude-sonnet-5","cost":{"input":2,"output":10,"cache_read":0.2}}}},
          "abacus": {"id":"abacus","models":{"claude-sonnet-5":{
            "id":"claude-sonnet-5","base_model":"anthropic/claude-sonnet-5",
            "cost":{"input":3,"output":15}}}}
        }
        """
        let officialFirst = """
        {
          "anthropic": {"id":"anthropic","models":{"claude-sonnet-5":{
            "id":"claude-sonnet-5","cost":{"input":2,"output":10,"cache_read":0.2}}}},
          "abacus": {"id":"abacus","models":{"claude-sonnet-5":{
            "id":"claude-sonnet-5","base_model":"anthropic/claude-sonnet-5",
            "cost":{"input":3,"output":15}}}},
          "unorouter": {"id":"unorouter","models":{"claude-sonnet-5":{
            "id":"claude-sonnet-5","base_model":"anthropic/claude-sonnet-5",
            "cost":{"input":1.44,"output":7.2}}}}
        }
        """

        let first = ModelsDevPricingCatalog.decodePricing(from: Data(providersFirst.utf8))
        let second = ModelsDevPricingCatalog.decodePricing(from: Data(officialFirst.utf8))

        XCTAssertEqual(first, second)
        assertDoubleEqual(first["claude-sonnet-5"]?.input ?? -1, 2)
        assertDoubleEqual(first["claude-sonnet-5"]?.output ?? -1, 10)
        assertDoubleEqual(first["abacus/claude-sonnet-5"]?.input ?? -1, 3)
        assertDoubleEqual(first["unorouter/claude-sonnet-5"]?.input ?? -1, 1.44)
    }

    func testProviderQualifiedLookupUsesThatProvidersPrice() throws {
        let json = """
        {
          "anthropic": {"id":"anthropic","models":{"claude-sonnet-5":{
            "cost":{"input":2,"output":10}}}},
          "abacus": {"id":"abacus","models":{"claude-sonnet-5":{
            "base_model":"anthropic/claude-sonnet-5","cost":{"input":3,"output":15}}}}
        }
        """
        let models = ModelsDevPricingCatalog.decodePricing(from: Data(json.utf8))
        let pricing = ModelPricing(models: models)

        let direct = try XCTUnwrap(pricing.cost(
            model: "claude-sonnet-5",
            input: 1_000_000,
            output: 0,
            cacheWrite: 0,
            cacheRead: 0
        ))
        let reseller = try XCTUnwrap(pricing.cost(
            model: "abacus/claude-sonnet-5",
            input: 1_000_000,
            output: 0,
            cacheWrite: 0,
            cacheRead: 0
        ))

        assertDoubleEqual(direct, 2)
        assertDoubleEqual(reseller, 3)
    }

    func testCatalogUsesDictionaryKeysWhenOptionalIDsAreMissing() {
        let json = """
        {"google":{"models":{"gemini-2.5-pro":{"cost":{"input":1.25,"output":10}}}}}
        """

        let pricing = ModelsDevPricingCatalog.decodePricing(from: Data(json.utf8))

        assertDoubleEqual(pricing["gemini-2.5-pro"]?.input ?? -1, 1.25)
        assertDoubleEqual(pricing["google/gemini-2.5-pro"]?.output ?? -1, 10)
    }

    func testUnqualifiedBaseModelStillInfersTheOfficialProvider() {
        let json = """
        {
          "z-reseller": {"models":{"codex-mini":{"base_model":"codex-mini",
            "cost":{"input":0.1,"output":0.2}}}},
          "openai": {"models":{"codex-mini":{"cost":{"input":1,"output":2}}}}
        }
        """

        let pricing = ModelsDevPricingCatalog.decodePricing(from: Data(json.utf8))

        assertDoubleEqual(pricing["codex-mini"]?.input ?? -1, 1)
        assertDoubleEqual(pricing["z-reseller/codex-mini"]?.input ?? -1, 0.1)
    }

    func testFlowPricingCatalogDecodesWrappedResponse() {
        let json = """
        {
          "status": "success",
          "statusCode": 200,
          "data": {
            "enabledModels": [
              {
                "name": "DeepSeek-V4-Pro",
                "vendor": "azure-foundry",
                "inputCostPerMillionToken": 1.74,
                "outputCostPerMillionToken": 3.48,
                "cacheReadTokenCost": 0.000000174,
                "cacheCreation5mTokenCost": 0.000000348
              }
            ],
            "disabledModels": []
          }
        }
        """

        let pricing = FlowPricingCatalog.decodePricing(from: Data(json.utf8))

        let direct = pricing["deepseek-v4-pro"]
        XCTAssertNotNil(direct)
        assertDoubleEqual(direct?.input ?? -1, 1.74)
        assertDoubleEqual(direct?.output ?? -1, 3.48)
        assertDoubleEqual(direct?.cacheRead ?? -1, 0.174)
        assertDoubleEqual(direct?.cacheWrite ?? -1, 0.348)

        XCTAssertNotNil(pricing["azure-foundry/deepseek-v4-pro"])
        XCTAssertNotNil(pricing["flow-azure-foundry/deepseek-v4-pro"])
        XCTAssertNotNil(pricing["flow-deepseek/deepseek-v4-pro"])
        XCTAssertNotNil(pricing["flow/deepseek-v4-pro"])
    }

    func testFlowPricingCatalogDecodesPerTokenPricingFormulas() {
        let json = """
        {
          "enabledModels": [
            {
              "name": "gemini-3.7-flash",
              "vendor": "google",
              "inputTokenCost": 0.00000075,
              "outputTokenCost": 0.00000375,
              "cacheReadTokenCost": 0.000000075,
              "cacheCreation1hTokenCost": 0.00000015
            }
          ]
        }
        """

        let pricing = FlowPricingCatalog.decodePricing(from: Data(json.utf8))

        let flash = pricing["gemini-3.7-flash"]
        XCTAssertNotNil(flash)
        assertDoubleEqual(flash?.input ?? -1, 0.75)
        assertDoubleEqual(flash?.output ?? -1, 3.75)
        assertDoubleEqual(flash?.cacheRead ?? -1, 0.075)
        assertDoubleEqual(flash?.cacheWrite ?? -1, 0.15)
        XCTAssertNotNil(pricing["flow-gemini/gemini-3.7-flash"])
    }

    func testFlowPricingCatalogFallbackContainsReferenceModels() {
        let fallback = FlowPricingCatalog.fallbackPricing()

        let deepseek = fallback["deepseek-v4-pro"]
        XCTAssertNotNil(deepseek)
        assertDoubleEqual(deepseek?.input ?? -1, 1.74)
        assertDoubleEqual(deepseek?.output ?? -1, 3.48)

        let gemini = fallback["gemini-3.7-flash"]
        XCTAssertNotNil(gemini)
        assertDoubleEqual(gemini?.input ?? -1, 0.75)
        assertDoubleEqual(gemini?.output ?? -1, 3.75)

        let codex = fallback["gpt-5.1-codex"]
        XCTAssertNotNil(codex)
        assertDoubleEqual(codex?.input ?? -1, 1.25)
        assertDoubleEqual(codex?.output ?? -1, 10.00)

        XCTAssertNotNil(fallback["claude-sonnet-4-6"])
        XCTAssertNotNil(fallback["gpt-5.6-sol"])
        XCTAssertNotNil(fallback["gpt-5.6-luna"])
        XCTAssertNotNil(fallback["flow-deepseek/deepseek-v4-pro"])
        XCTAssertNotNil(fallback["flow-gemini/gemini-3.7-flash"])
    }

    func testUniversalNormalizationRemovesContextSuffixesAndGatewayPrefixes() {
        // Context suffixes
        XCTAssertEqual(ModelPricing.normalizeModel("DeepSeek-V4-Pro[1m]"), "deepseek-v4-pro")
        XCTAssertEqual(ModelPricing.normalizeModel("claude-3-5-sonnet[200k]"), "claude-3-5-sonnet")
        XCTAssertEqual(ModelPricing.normalizeModel("gpt-4o[128k]"), "gpt-4o")

        // Gateway prefixes
        XCTAssertEqual(ModelPricing.normalizeModel("flow-deepseek/DeepSeek-V4-Pro"), "deepseek-v4-pro")
        XCTAssertEqual(ModelPricing.normalizeModel("flow-gemini/gemini-3.7-flash"), "gemini-3.7-flash")
        XCTAssertEqual(ModelPricing.normalizeModel("flow/deepseek-v4-pro"), "deepseek-v4-pro")
        XCTAssertEqual(ModelPricing.normalizeModel("azure-foundry/deepseek-v4-pro"), "deepseek-v4-pro")
        XCTAssertEqual(ModelPricing.normalizeModel("azure-openai/gpt-5.6-luna"), "gpt-5.6-luna")
        XCTAssertEqual(ModelPricing.normalizeModel("google-gemini/gemini-3.7-flash"), "gemini-3.7-flash")
        XCTAssertEqual(ModelPricing.normalizeModel("amazon-bedrock/claude-3-5-sonnet"), "claude-3-5-sonnet")
        XCTAssertEqual(ModelPricing.normalizeModel("azure-ai-speech/whisper"), "whisper")
    }

    func testHarnessModelsCostResolutionWithFlowFallback() throws {
        let pricing = ModelPricing.load()

        // Claude Code with context suffix
        let claudeCost = try XCTUnwrap(pricing.cost(
            model: "DeepSeek-V4-Pro[1m]",
            input: 1_000_000,
            output: 1_000_000,
            cacheWrite: 0,
            cacheRead: 0
        ))
        assertDoubleEqual(claudeCost, 1.74 + 3.48)

        // OpenCode with flow-deepseek prefix
        let openCodeDeepSeekCost = try XCTUnwrap(pricing.cost(
            model: "flow-deepseek/DeepSeek-V4-Pro",
            input: 1_000_000,
            output: 1_000_000,
            cacheWrite: 0,
            cacheRead: 0
        ))
        assertDoubleEqual(openCodeDeepSeekCost, 1.74 + 3.48)

        // OpenCode with flow-gemini prefix
        let openCodeGeminiCost = try XCTUnwrap(pricing.cost(
            model: "flow-gemini/gemini-3.7-flash",
            input: 1_000_000,
            output: 1_000_000,
            cacheWrite: 0,
            cacheRead: 0
        ))
        assertDoubleEqual(openCodeGeminiCost, 0.75 + 3.75)

        // Codex model
        let codexCost = try XCTUnwrap(pricing.cost(
            model: "gpt-5.1-codex",
            input: 1_000_000,
            output: 1_000_000,
            cacheWrite: 0,
            cacheRead: 0
        ))
        assertDoubleEqual(codexCost, 1.25 + 10.00)
    }

    func testFlowCatalogTakesPrecedenceOverModelsDev() {
        let pricing = ModelPricing.load()

        // In models.dev fallback, gemini-3.7-flash was 0.35 / 0.70.
        // In Flow catalog fallback, gemini-3.7-flash is corporate 0.75 / 3.75.
        let cost = pricing.cost(
            model: "gemini-3.7-flash",
            input: 1_000_000,
            output: 0,
            cacheWrite: 0,
            cacheRead: 0
        )
        XCTAssertNotNil(cost)
        assertDoubleEqual(cost!, 0.75)
    }

    func testModelPricingCachingAndClearCache() {
        let p1 = ModelPricing.load()
        let p2 = ModelPricing.load()
        XCTAssertEqual(p1.models, p2.models)

        ModelPricing.clearCache()
        let p3 = ModelPricing.load()
        XCTAssertEqual(p1.models, p3.models)
    }
}

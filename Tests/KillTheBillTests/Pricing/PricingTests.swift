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

    func testCustomProviderPricingIncludesAliases() {
        let provider = CustomProviderConfig(
            id: "proxy",
            name: "Proxy",
            files: nil,
            event: nil,
            pricing: [
                CustomProviderModelPricing(
                    model: "proxy/model-a",
                    aliases: ["model-a"],
                    input: 0.5,
                    output: 2,
                    cacheWrite: nil,
                    cacheRead: 0.1
                )
            ]
        )

        let pricing = CustomProviderLoader.loadCustomPricing(from: [provider])

        assertDoubleEqual(pricing["proxy/model-a"]?.input ?? -1, 0.5)
        assertDoubleEqual(pricing["model-a"]?.cacheRead ?? -1, 0.1)
    }
}

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
}

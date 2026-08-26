import Foundation
import XCTest
@testable import KillTheBill

final class FlowBudgetClientTests: XCTestCase {
    func testParsesSingleLevelWrappedResponse() throws {
        let fetchedAt = Date(timeIntervalSince1970: 123)
        let json = """
        {"data":{"percentage":39.3,"consumed_usd":117.9,"effective_limit":300,"limit_type":"DEFAULT",
        "status":"ok","renewal_date":"2026-09-01T00:00:00.000Z"}}
        """
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8), fetchedAt: fetchedAt))

        assertDoubleEqual(try XCTUnwrap(usage.reportedPercentage), 39.3)
        assertDoubleEqual(usage.consumedUSD, 117.9)
        assertDoubleEqual(try XCTUnwrap(usage.effectiveLimit), 300)
        XCTAssertEqual(usage.fetchedAt, fetchedAt)
        XCTAssertFalse(usage.isUnlimited)
    }

    func testParsesDoublyWrappedResponse() throws {
        let json = """
        {"data":{"data":{"percentage":39.3,"consumed_usd":117.9,"effective_limit":300,
        "limit_type":"DEFAULT","status":"ok","renewal_date":"2026-09-01T00:00:00.000Z"}}}
        """
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))

        assertDoubleEqual(usage.consumedUSD, 117.9)
        assertDoubleEqual(try XCTUnwrap(usage.effectiveLimit), 300)
    }

    /// Matches the user-supplied sample response, which is nested one level
    /// deeper (.data.data.data) than the live endpoint was observed to return
    /// in manual testing (.data.data) — unwrapNested must handle both shapes.
    func testParsesTriplyWrappedSampleResponse() throws {
        let json = """
        {"status":"success","statusCode":200,"data":{"data":{"status":"success","statusCode":200,
        "data":{"user_id":"92ad018c-fe6e-4dbf-8cbe-4b8263a1bed0","requests_used":0,"limit":300,
        "limit_type":"INDIVIDUAL","percentage":106.34704198333182,"status":"blocked",
        "renewal_date":"2026-09-01T00:00:00.000Z","rate_limit_request":null,
        "consumed_usd":319.0411259499955,"budget_limit":300,"effective_limit":300,
        "individual_budget":10000,"global_admin_exception":false}}}}
        """

        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))
        let resolved = usage.resolved(for: .automatic)

        assertDoubleEqual(usage.consumedUSD, 319.0411259499955)
        assertDoubleEqual(try XCTUnwrap(usage.limit), 300)
        assertDoubleEqual(try XCTUnwrap(usage.budgetLimit), 300)
        assertDoubleEqual(try XCTUnwrap(usage.effectiveLimit), 300)
        assertDoubleEqual(try XCTUnwrap(usage.individualBudget), 10_000)
        assertDoubleEqual(try XCTUnwrap(usage.reportedPercentage), 106.34704198333182)
        assertDoubleEqual(try XCTUnwrap(resolved.limit), 10_000)
        assertDoubleEqual(resolved.percentage, 3.190411259499955)
        XCTAssertEqual(resolved.limitSource, .individual)
    }

    func testExplicitLimitPoliciesUseTheirOwnPropertiesAndRecomputePercentage() throws {
        let json = """
        {"data":{"percentage":40,"consumed_usd":120,"limit":250,"budget_limit":300,
        "effective_limit":400,"individual_budget":1000,"limit_type":"INDIVIDUAL"}}
        """
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))

        let individual = usage.resolved(for: .individual)
        assertDoubleEqual(try XCTUnwrap(individual.limit), 1_000)
        assertDoubleEqual(individual.percentage, 12)

        let tenant = usage.resolved(for: .tenant)
        assertDoubleEqual(try XCTUnwrap(tenant.limit), 300)
        assertDoubleEqual(tenant.percentage, 40)

        let effective = usage.resolved(for: .effective)
        assertDoubleEqual(try XCTUnwrap(effective.limit), 400)
        assertDoubleEqual(effective.percentage, 30)
    }

    func testTenantPolicyFallsBackToLegacyLimitProperty() throws {
        let json = #"{"data":{"consumed_usd":50,"limit":200,"limit_type":"DEFAULT"}}"#
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))
        let resolved = usage.resolved(for: .tenant)

        assertDoubleEqual(try XCTUnwrap(resolved.limit), 200)
        assertDoubleEqual(resolved.percentage, 25)
        XCTAssertEqual(resolved.limitSource, .tenant)
    }

    func testMissingExplicitLimitIsReportedAsUnavailable() throws {
        let json = #"{"data":{"percentage":50,"consumed_usd":150,"effective_limit":300,"limit_type":"DEFAULT"}}"#
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))
        let resolved = usage.resolved(for: .individual)

        XCTAssertNil(resolved.limit)
        XCTAssertEqual(resolved.percentage, 0)
        XCTAssertFalse(resolved.isUnlimited)
        XCTAssertTrue(resolved.isLimitUnavailable)
    }

    func testResponseWithoutAnyLimitIsUnavailableRatherThanUnlimited() throws {
        let json = #"{"data":{"percentage":12.5,"consumed_usd":25,"limit_type":"DEFAULT"}}"#
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))
        let resolved = usage.resolved(for: .automatic)

        XCTAssertFalse(usage.isUnlimited)
        XCTAssertFalse(resolved.isUnlimited)
        XCTAssertTrue(resolved.isLimitUnavailable)
        XCTAssertNil(resolved.limit)
        assertDoubleEqual(resolved.percentage, 12.5)
    }

    func testNoLimitTypeIsTreatedAsUnlimitedNotZeroConsumption() throws {
        let json = """
        {"data":{"percentage":0,"consumed_usd":42.5,"effective_limit":0,"limit_type":"NO_LIMIT",
        "status":"ok","renewal_date":"2026-09-01T00:00:00.000Z"}}
        """
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))
        let resolved = usage.resolved(for: .automatic)

        XCTAssertTrue(usage.isUnlimited)
        XCTAssertTrue(resolved.isUnlimited)
        XCTAssertNil(resolved.limit)
        assertDoubleEqual(usage.consumedUSD, 42.5)
    }

    func testMissingPercentageFieldStillParsesAndComputesFromSelectedLimit() throws {
        let json = #"{"data":{"consumed_usd":10,"effective_limit":300}}"#
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))

        XCTAssertNil(usage.reportedPercentage)
        assertDoubleEqual(usage.resolved(for: .automatic).percentage, 10.0 / 300.0 * 100)
    }

    func testMissingConsumptionFieldFailsToParse() {
        let json = #"{"data":{"percentage":10,"effective_limit":300}}"#
        XCTAssertNil(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))
    }

    func testCacheRoundTripPreservesEveryRawLimit() throws {
        let usage = FlowBudgetUsage(
            reportedPercentage: 106.3,
            consumedUSD: 319,
            limit: 300,
            budgetLimit: 400,
            effectiveLimit: 500,
            individualBudget: 10_000,
            limitType: "INDIVIDUAL",
            renewalDate: "2026-09-01",
            status: "blocked",
            fetchedAt: Date(timeIntervalSince1970: 123)
        )

        let data = try XCTUnwrap(FlowBudgetClient.encodeCachedUsage(usage))
        let restored = try XCTUnwrap(FlowBudgetClient.decodeCachedUsage(data))

        XCTAssertEqual(restored, usage)
    }

    func testLegacyCacheMigratesPercentageAndEffectiveLimit() throws {
        let json = """
        {"percentage":39.3,"consumedUSD":117.9,"effectiveLimit":300,
        "limitType":"DEFAULT","renewalDate":"2026-09-01","status":"ok","fetchedAt":123}
        """

        let usage = try XCTUnwrap(FlowBudgetClient.decodeCachedUsage(Data(json.utf8)))

        assertDoubleEqual(try XCTUnwrap(usage.reportedPercentage), 39.3)
        assertDoubleEqual(try XCTUnwrap(usage.effectiveLimit), 300)
        XCTAssertNil(usage.individualBudget)
    }

    func testStalenessUsesConfiguredTTLAndInjectedClock() {
        let now = Date(timeIntervalSince1970: 1_000)
        let usage = FlowBudgetUsage(
            reportedPercentage: nil,
            consumedUSD: 0,
            limit: nil,
            budgetLimit: nil,
            effectiveLimit: 300,
            individualBudget: nil,
            limitType: "DEFAULT",
            renewalDate: "",
            status: "",
            fetchedAt: now.addingTimeInterval(-59)
        )

        XCTAssertFalse(FlowBudgetClient.isStale(usage, ttl: 60, now: now))
        XCTAssertTrue(FlowBudgetClient.isStale(usage, ttl: 30, now: now))
        XCTAssertTrue(FlowBudgetClient.isStale(nil, ttl: 60, now: now))
    }

    func testJWTPayloadExtractsClientSecretAndTenant() throws {
        let payload: [String: Any] = ["clientSecret": "secret-123", "tenant": "acme"]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadSegment = base64URLEncode(payloadData)
        let token = "header.\(payloadSegment).signature"

        let context = try XCTUnwrap(FlowBudgetClient.extractAuthContext(fromJWT: token))

        XCTAssertEqual(context.clientSecret, "secret-123")
        XCTAssertEqual(context.tenant, "acme")
    }

    func testJWTWithoutClientSecretFailsToExtractContext() throws {
        let payload: [String: Any] = ["tenant": "acme"]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let token = "header.\(base64URLEncode(payloadData)).signature"

        XCTAssertNil(FlowBudgetClient.extractAuthContext(fromJWT: token))
    }

    func testFlowModelsDecodingFromDifferentNestingLevels() throws {
        // Deep nested wrapper (data.data.enabledModels)
        let deepNestedJson = """
        {"data":{"data":{"enabledModels":[{"name":"gpt-5.6-sol","vendor":"openai","inputCostPerMillionToken":2.5,"outputCostPerMillionToken":10.0}]}}}
        """
        let pricing1 = FlowPricingCatalog.decodePricing(from: Data(deepNestedJson.utf8))
        assertDoubleEqual(pricing1["gpt-5.6-sol"]?.input ?? -1, 2.5)
        assertDoubleEqual(pricing1["gpt-5.6-sol"]?.output ?? -1, 10.0)

        // Direct array
        let arrayJson = """
        [{"name":"deepseek-chat","vendor":"deepseek","inputCostPerMillionToken":0.14,"outputCostPerMillionToken":0.28}]
        """
        let pricing2 = FlowPricingCatalog.decodePricing(from: Data(arrayJson.utf8))
        assertDoubleEqual(pricing2["deepseek-chat"]?.input ?? -1, 0.14)
        assertDoubleEqual(pricing2["deepseek-chat"]?.output ?? -1, 0.28)
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

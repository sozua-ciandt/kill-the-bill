import Foundation
import XCTest
@testable import KillTheBill

final class FlowBudgetClientTests: XCTestCase {
    func testParsesSingleLevelWrappedResponse() throws {
        let json = """
        {"data":{"percentage":39.3,"consumed_usd":117.9,"effective_limit":300,"limit_type":"DEFAULT",
        "status":"ok","renewal_date":"2026-09-01T00:00:00.000Z"}}
        """
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))

        assertDoubleEqual(usage.percentage, 39.3)
        assertDoubleEqual(usage.consumedUSD, 117.9)
        assertDoubleEqual(usage.effectiveLimit, 300)
        XCTAssertFalse(usage.isUnlimited)
    }

    func testParsesDoublyWrappedResponse() throws {
        let json = """
        {"data":{"data":{"percentage":39.3,"consumed_usd":117.9,"effective_limit":300,
        "limit_type":"DEFAULT","status":"ok","renewal_date":"2026-09-01T00:00:00.000Z"}}}
        """
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))

        assertDoubleEqual(usage.consumedUSD, 117.9)
        assertDoubleEqual(usage.effectiveLimit, 300)
    }

    /// Matches the user-supplied sample response, which is nested one level
    /// deeper (.data.data.data) than the live endpoint was observed to return
    /// in manual testing (.data.data) — unwrapNested must handle both shapes.
    func testParsesTriplyWrappedSampleResponse() throws {
        let json = """
        {"status":"success","statusCode":200,"data":{"data":{"status":"success","statusCode":200,
        "data":{"user_id":"92ad018c-fe6e-4dbf-8cbe-4b8263a1bed0","requests_used":0,"limit":300,
        "limit_type":"DEFAULT","percentage":39.30292973333337,"status":"ok",
        "renewal_date":"2026-09-01T00:00:00.000Z","rate_limit_request":null,
        "consumed_usd":117.90878920000013,"budget_limit":300,"effective_limit":300,
        "individual_budget":null,"global_admin_exception":false}}}}
        """

        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))

        assertDoubleEqual(usage.consumedUSD, 117.90878920000013)
        assertDoubleEqual(usage.effectiveLimit, 300)
        assertDoubleEqual(usage.percentage, 39.30292973333337)
    }

    func testNoLimitTypeIsTreatedAsUnlimitedNotZeroConsumption() throws {
        let json = """
        {"data":{"percentage":0,"consumed_usd":42.5,"effective_limit":0,"limit_type":"NO_LIMIT",
        "status":"ok","renewal_date":"2026-09-01T00:00:00.000Z"}}
        """
        let usage = try XCTUnwrap(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))

        XCTAssertTrue(usage.isUnlimited)
        assertDoubleEqual(usage.consumedUSD, 42.5)
    }

    func testMissingPercentageFieldFailsToParse() {
        let json = #"{"data":{"consumed_usd":10,"effective_limit":300}}"#
        XCTAssertNil(FlowBudgetClient.parseBudgetResponse(Data(json.utf8)))
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

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

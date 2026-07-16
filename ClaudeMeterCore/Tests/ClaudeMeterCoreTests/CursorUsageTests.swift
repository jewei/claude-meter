import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("Cursor usage")
struct CursorUsageTests {

    @Test func decodesAndNormalizesPlanUsage() throws {
        let json = """
            {
              "billingCycleStart": "1750000000000",
              "billingCycleEnd": "1752592200000",
              "planUsage": {
                "totalSpend": 1240,
                "limit": 2000,
                "autoPercentUsed": 10.0,
                "apiPercentUsed": 100.0,
                "totalPercentUsed": 62.0
              },
              "enabled": true
            }
            """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_751_000_000)
        let usage = response.usage(planName: "pro", email: "x@y.z", now: now)

        #expect(usage.percentUsed == 62.0)
        #expect(usage.autoPercentUsed == 10.0)
        #expect(usage.apiPercentUsed == 100.0)
        #expect(usage.spendUsd == 12.40)
        #expect(usage.limitUsd == 20.00)
        #expect(usage.periodEnd == Date(timeIntervalSince1970: 1_752_592_200))
        #expect(usage.spendText == "$12.40")
        #expect(usage.planName == "pro")
        #expect(usage.displayPlanName == "Pro")
    }

    @Test func zeroLimitMeansNoFixedLimit() throws {
        let json = """
            { "planUsage": { "totalSpend": 500, "limit": 0, "totalPercentUsed": 0 }, "enabled": true }
            """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(json.utf8))
        let usage = response.usage(planName: nil, email: nil, now: Date())
        #expect(usage.limitUsd == nil)
        #expect(usage.spendText == "$5.00")
    }

    @Test func optionalBreakdownStaysMissingForOlderResponses() throws {
        let json = """
            { "planUsage": { "totalPercentUsed": 22 }, "enabled": true }
            """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(json.utf8))
        let usage = response.usage(planName: "pro_plus", email: nil, now: Date())

        #expect(usage.percentUsed == 22)
        #expect(usage.autoPercentUsed == nil)
        #expect(usage.apiPercentUsed == nil)
        #expect(usage.displayPlanName == "Pro+")
    }

    @Test func clampsBreakdownPercentagesForDisplay() {
        let usage = CursorUsage(
            percentUsed: 101,
            autoPercentUsed: -1,
            apiPercentUsed: 103,
            planName: "  Custom Plan  ")

        #expect(usage.clampedPercent == 100)
        #expect(usage.clampedAutoPercent == 0)
        #expect(usage.clampedAPIPercent == 100)
        #expect(usage.displayPlanName == "Custom Plan")
    }

    @Test func parsesDateFromMillisSecondsAndISO() {
        #expect(
            parseEpochOrISODate("1752592200000")
                == Date(timeIntervalSince1970: 1_752_592_200))
        #expect(
            parseEpochOrISODate("1752592200")
                == Date(timeIntervalSince1970: 1_752_592_200))
        #expect(parseEpochOrISODate("2025-07-15T14:30:00Z") != nil)
        #expect(parseEpochOrISODate("") == nil)
        #expect(parseEpochOrISODate(nil) == nil)
    }

    @Test func decodesJWTExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = Self.makeJWT(exp: now.addingTimeInterval(3600).timeIntervalSince1970)
        let exp = CursorTokenStore.expiry(of: token)
        #expect(exp == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(CursorTokenStore.isExpiringSoon(token, buffer: 300, now: now) == false)
        #expect(
            CursorTokenStore.isExpiringSoon(token, buffer: 300, now: now.addingTimeInterval(3500)))
    }

    @Test func opaqueTokenTreatedAsExpiringSoon() {
        #expect(CursorTokenStore.expiry(of: "not-a-jwt") == nil)
        #expect(CursorTokenStore.isExpiringSoon("not-a-jwt") == true)
    }

    @Test func unquotesJsonStoredValues() {
        #expect(CursorTokenStore.unquoteStoredValue("\"token-value\"") == "token-value")
        #expect(CursorTokenStore.unquoteStoredValue("plain") == "plain")
    }

    @Test func disabledUsageThrows() throws {
        let json = """
            { "planUsage": { "totalSpend": 0, "limit": 0, "totalPercentUsed": 0 }, "enabled": false }
            """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(json.utf8))
        #expect(throws: CursorError.usageDisabled) {
            try response.validatedUsage(planName: nil, email: nil, now: Date())
        }
    }

    @Test func refreshResponseDecodesRotatedRefreshToken() throws {
        let json = """
            { "access_token": "new-access", "refresh_token": "new-refresh" }
            """
        let response = try JSONDecoder().decode(CursorOAuthResponse.self, from: Data(json.utf8))
        #expect(response.accessToken == "new-access")
        #expect(response.refreshToken == "new-refresh")
    }

    // MARK: - Helpers

    private static func makeJWT(exp: TimeInterval) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": exp])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}

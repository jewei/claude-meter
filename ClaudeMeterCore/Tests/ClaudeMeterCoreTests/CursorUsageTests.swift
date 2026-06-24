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
          "planUsage": { "totalSpend": 1240, "limit": 2000, "totalPercentUsed": 62.0 },
          "enabled": true
        }
        """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_751_000_000)
        let usage = response.usage(planName: "pro", email: "x@y.z", now: now)

        #expect(usage.percentUsed == 62.0)
        #expect(usage.spendUsd == 12.40)
        #expect(usage.limitUsd == 20.00)
        #expect(usage.periodEnd == Date(timeIntervalSince1970: 1_752_592_200))
        #expect(usage.spendText == "$12.40")
        #expect(usage.planName == "pro")
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

    @Test func parsesDateFromMillisSecondsAndISO() {
        #expect(CursorUsageResponse.parseDate("1752592200000") == Date(timeIntervalSince1970: 1_752_592_200))
        #expect(CursorUsageResponse.parseDate("1752592200") == Date(timeIntervalSince1970: 1_752_592_200))
        #expect(CursorUsageResponse.parseDate("2025-07-15T14:30:00Z") != nil)
        #expect(CursorUsageResponse.parseDate("") == nil)
        #expect(CursorUsageResponse.parseDate(nil) == nil)
    }

    @Test func decodesJWTExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = Self.makeJWT(exp: now.addingTimeInterval(3600).timeIntervalSince1970)
        let exp = CursorTokenStore.expiry(of: token)
        #expect(exp == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(CursorTokenStore.isExpiringSoon(token, buffer: 300, now: now) == false)
        #expect(CursorTokenStore.isExpiringSoon(token, buffer: 300, now: now.addingTimeInterval(3500)))
    }

    @Test func nonJWTHasNoExpiryAndIsNotConsideredExpiring() {
        #expect(CursorTokenStore.expiry(of: "not-a-jwt") == nil)
        #expect(CursorTokenStore.isExpiringSoon("not-a-jwt") == false)
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

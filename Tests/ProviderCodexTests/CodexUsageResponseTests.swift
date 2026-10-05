import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    @Suite struct CodexUsageResponseTests {
        private let home = CodexHome(
            directory: URL(fileURLWithPath: "/tmp/codex"), isImplicit: true)

        private func quota(_ text: String) throws -> CodexQuota {
            try CodexUsageResponse.quota(from: Data(text.utf8))
        }

        @Test func mapsBothWindowsCreditsAndPlan() throws {
            let usage = try quota(CodexFixtures.usage)
                .usage(for: home, observedAt: .reference(), owner: nil)
            #expect(usage.name == "Codex")
            #expect(usage.plan == "Plus")
            #expect(usage.windows.map(\.id) == ["primary", "secondary"])
            #expect(usage.windows.map(\.title) == ["Session", "Weekly"])
            #expect(usage.windows.map(\.kind) == [.session, .weekly])
            #expect(usage.windows.map(\.usedPercent) == [9, 43])
            #expect(usage.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_791_118_800))
            #expect(usage.balances == [Balance(kind: .credits, amount: 7.5, unit: .credits)])
            #expect(usage.resetAllowance == nil)
            #expect(usage.observedAt == .reference())
            #expect(usage.attemptedAt == .reference())
        }

        /// Decision 2: numbers are Double, and numeric strings are accepted.
        @Test func acceptsFractionsAndNumericStrings() throws {
            let result = try quota(
                #"""
                {"rate_limit":{"primary_window":{"used_percent":12.5,"reset_at":"1791118800",
                  "limit_window_seconds":"18000.0"}},"credits":{"balance":3.25},
                 "rate_limit_reset_credits":{"available_count":"2"}}
                """#)
            #expect(result.primary?.usedPercent == 12.5)
            #expect(result.primary?.resetsAt == Date(timeIntervalSince1970: 1_791_118_800))
            #expect(result.primary?.duration == 18_000)
            #expect(result.credits?.amount == Decimal(string: "3.25"))
            #expect(result.resetCount == 2)
        }

        @Test func aMissingSecondaryWindowIsAllowed() throws {
            let result = try quota(
                #"{"rate_limit":{"primary_window":{"used_percent":1},"secondary_window":null}}"#)
            #expect(result.primary != nil)
            #expect(result.secondary == nil)
        }

        @Test(arguments: [
            #"{"rate_limit":{"primary_window":{"used_percent":[]}}}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":"twelve"}}}"#,
            #"{"rate_limit":{"primary_window":{"reset_at":true}}}"#,
            #"{"rate_limit":{"primary_window":[]}}"#,
            #"{"rate_limit":"none"}"#,
            "not json", "[]",
        ])
        func malformedQuotaFailsTheRead(body: String) {
            #expect(throws: CodexError.unexpectedResponse) { try quota(body) }
        }

        @Test(arguments: [#"{"balance":[]}"#, #"{"unlimited":"invalid"}"#, "[]", "null"])
        func malformedMetadataKeepsQuota(credits: String) throws {
            let result = try quota(
                """
                {"rate_limit":{"primary_window":{"used_percent":37}},
                 "plan_type":[],"credits":\(credits),"rate_limit_reset_credits":{"available_count":[]}}
                """)
            #expect(result.primary?.usedPercent == 37)
            #expect(result.credits == nil)
            #expect(result.plan == nil)
            #expect(result.resetCount == nil)
        }

        @Test(arguments: [
            #"{"credits":{"unlimited":false,"balance":"nan"}}"#,
            #"{"credits":{"balance":"inf"}}"#,
            #"{"credits":{"balance":[]}}"#,
            #"{"plan_type":"plus","rate_limit_reset_credits":{"available_count":2}}"#,
            "{}",
        ])
        func metadataAloneIsNoUsage(body: String) {
            #expect(throws: CodexError.noUsageData) { try quota(body) }
        }

        @Test func unlimitedCreditsHaveNoAmount() throws {
            let result = try quota(#"{"credits":{"unlimited":true,"balance":"0"}}"#)
            #expect(
                result.credits
                    == Balance(kind: .credits, amount: nil, unit: .credits, isUnlimited: true))
        }

        @Test func overLimitAndUnknownValuesStayHonest() throws {
            let result = try quota(
                #"{"rate_limit":{"primary_window":{"used_percent":140,"reset_at":1e308,"limit_window_seconds":-5},"secondary_window":{}}}"#
            )
            let usage = result.usage(for: home, observedAt: .reference(), owner: nil)
            #expect(usage.windows[0].usedPercent == 100)
            #expect(usage.windows[0].isOverLimit)
            #expect(usage.windows[0].resetsAt == nil)
            #expect(usage.windows[0].title == "Session")
            #expect(usage.windows[1].usedPercent == nil)
            #expect(usage.windows[1].title == "Weekly")
            #expect(usage.windows[1].kind == .weekly)
        }

        @Test(arguments: [
            (18_000.0, "Session", QuotaWindow.Kind.session), (86_400, "Session", .session),
            (604_800, "Weekly", .weekly), (172_800, "Weekly", .weekly),
            (7_200, "Session", .session),
            (1_800, "Session", .session), (1e308, "Weekly", .weekly),
        ])
        func titleAndKindComeFromTheDuration(seconds: Double, title: String, kind: QuotaWindow.Kind)
        {
            let window = CodexQuota.quotaWindow(
                CodexQuota.Window(usedPercent: 1, resetsAt: nil, duration: seconds), slot: .primary)
            #expect(window.title == title)
            #expect(window.kind == kind)
        }

        /// CDX-11: every upstream `PlanType` value has a readable name.
        @Test(arguments: [
            ("free", "Free"), ("go", "Go"), ("plus", "Plus"), ("prolite", "Pro 5X"),
            ("pro-lite", "Pro 5X"), ("pro", "Pro 20X"), ("promax", "Pro Max"), ("team", "Team"),
            ("self_serve_business_prolite", "Business"),
            ("self_serve_business_usage_based", "Business"), ("business", "Business"),
            ("ent26", "Enterprise"), ("enterprise_cbp_automation", "Enterprise"),
            ("enterprise_cbp_usage_based", "Enterprise"), ("enterprise", "Enterprise"),
            ("edu", "Edu"), ("education", "Edu"), ("edu_plus", "Edu Plus"),
            ("edu_pro", "Edu Pro"), (" Custom ", "Custom"), ("PLUS", "Plus"),
        ])
        func planNames(id: String, name: String) {
            #expect(CodexPlan.displayName(id) == name)
        }

        @Test func unknownAndEmptyPlansHaveNoName() {
            #expect(CodexPlan.displayName("unknown") == nil)
            #expect(CodexPlan.displayName("") == nil)
            #expect(CodexPlan.displayName(nil) == nil)
        }

        @Test func resetDetailsKeepAvailableUnexpiredRows() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let body = """
                {"available_count":3,"credits":[
                  {"status":"available","title":"Full reset","expires_at":"2027-02-01T00:00:00.123456Z"},
                  {"status":"available","title":"No expiry","expires_at":null},
                  {"status":"available","title":"Expired","expires_at":"2020-01-01T00:00:00Z"},
                  {"status":"available","title":"Expires now","expires_at":"2027-01-15T08:00:00Z"},
                  {"status":"redeemed","expires_at":"2028-01-01T00:00:00Z"},
                  {"status":"redeeming","expires_at":"2028-01-01T00:00:00Z"},
                  {"status":"expired","expires_at":"2028-01-01T00:00:00Z"},
                  "not a row"]}
                """
            let rows = CodexUsageResponse.resets(from: Data(body.utf8), expectedCount: 3, now: now)
            #expect(rows?.map(\.title) == ["Full reset", "No expiry"])
            let expiry = rows?.first?.expiresAt?.timeIntervalSince1970 ?? 0
            #expect(abs(expiry - 1_801_440_000.123) < 0.001)
        }

        @Test(arguments: [
            "not JSON", #"{"available_count":3,"credits":"invalid"}"#, #"{"available_count":3}"#,
            #"{"available_count":-1,"credits":[]}"#,
            #"{"available_count":2,"credits":[{"status":"available","title":"Other count"}]}"#,
        ])
        func unusableResetDetailsAreNil(body: String) {
            #expect(
                CodexUsageResponse.resets(
                    from: Data(body.utf8), expectedCount: 3, now: .reference()) == nil)
        }

        @Test(arguments: [
            "null", "1e308", "{}", "\"invalid\"", "\"3000-01-01T00:00:00Z\"",
            "\"1969-12-31T23:59:59Z\"",
        ])
        func invalidResetExpiryStaysUnknown(expiry: String) throws {
            let body =
                #"{"available_count":1,"credits":[{"status":"available","expires_at":\#(expiry)}]}"#
            let rows = CodexUsageResponse.resets(
                from: Data(body.utf8), expectedCount: 1, now: .reference())
            #expect(rows?.count == 1)
            #expect(rows?.first?.expiresAt == nil)
            #expect(rows?.first?.title == "Usage reset")
            _ = try JSONEncoder.meter.encode(ResetAllowance(available: 1, resets: rows ?? []))
        }
    }
}

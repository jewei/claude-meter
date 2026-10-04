import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    @Suite struct CodexAppServerResultTests {
        private let home = CodexHome(
            directory: URL(fileURLWithPath: "/tmp/work"), isImplicit: false)

        private func quota(
            _ rateLimits: String, account: String? = CodexFixtures.chatGPTAccount,
            now: Date = .reference()
        ) throws -> CodexQuota {
            try CodexAppServerResult.quota(
                account: account.flatMap(CodexFixtures.value),
                rateLimits: CodexFixtures.value(rateLimits), now: now)
        }

        @Test func mapsRateLimitsToWindowsCreditsResetsAndPlan() throws {
            let usage = try quota(CodexFixtures.rateLimits)
                .usage(for: home, observedAt: .reference(), owner: nil)
            #expect(usage.name == "work")
            #expect(usage.windows.map(\.title) == ["5h", "Weekly"])
            #expect(usage.windows.map(\.usedPercent) == [22, 43])
            #expect(usage.windows.map(\.percentLeft) == [78, 57])
            #expect(usage.plan == "Pro 20X")
            #expect(usage.balances.first?.amount == Decimal(string: "112.4"))
            #expect(usage.resetAllowance?.available == 4)
            #expect(usage.resetAllowance?.resets.count == 2)
            #expect(
                usage.resetAllowance?.resets.first?.expiresAt
                    == Date(timeIntervalSince1970: 1_791_201_600))
        }

        /// Decision 7: keyed windows fill missing slots with readable titles, never limit IDs.
        @Test func keyedWindowsFillMissingSlotsWithReadableTitles() throws {
            let result = try quota(
                #"""
                {"rateLimits":{"rateLimitsByLimitId":{
                  "codex_burst":{"usedPercent":12,"windowDurationMins":60},
                  "codex_5h":{"usedPercent":31,"windowDurationMins":300},
                  "codex_weekly":{"usedPercent":64,"windowDurationMins":10080}}}}
                """#)
            let windows = result.usage(for: home, observedAt: .reference(), owner: nil).windows
            #expect(windows.map(\.usedPercent) == [31, 64])
            #expect(windows.map(\.title) == ["5h", "Weekly"])
            #expect(!windows.contains { $0.title.hasPrefix("codex_") })
        }

        @Test func positionalWindowsWinAndKeyedOnesFillOnlyTheGap() throws {
            let both = try quota(
                #"""
                {"rateLimits":{"primary":{"usedPercent":22,"windowDurationMins":300},
                  "secondary":{"usedPercent":43,"windowDurationMins":10080},
                  "rateLimitsByLimitId":{"codex_5h":{"usedPercent":90,"windowDurationMins":300},
                    "codex_weekly":{"usedPercent":91,"windowDurationMins":10080}}}}
                """#)
            #expect(both.primary?.usedPercent == 22)
            #expect(both.secondary?.usedPercent == 43)

            let gap = try quota(
                #"""
                {"rateLimits":{"primary":{"usedPercent":22,"windowDurationMins":300},
                  "rate_limits_by_limit_id":{"codex_weekly":{"usedPercent":64,"windowDurationMins":10080}}}}
                """#)
            #expect(gap.primary?.usedPercent == 22)
            #expect(gap.secondary?.usedPercent == 64)
        }

        /// Decision 7: one malformed keyed window drops only itself.
        @Test func aMalformedKeyedWindowDropsOnlyItself() throws {
            let result = try quota(
                #"""
                {"rateLimits":{"rateLimitsByLimitId":{
                  "a_broken":{"usedPercent":"high","windowDurationMins":300},
                  "b_session":{"usedPercent":20,"windowDurationMins":300},
                  "c_weekly":{"usedPercent":50,"windowDurationMins":10080},
                  "d_not_an_object":[]}}}
                """#)
            #expect(result.primary?.usedPercent == 20)
            #expect(result.secondary?.usedPercent == 50)
        }

        @Test func aMalformedPositionalWindowDropsOnlyItself() throws {
            let result = try quota(
                #"{"rateLimits":{"primary":{"usedPercent":[]},"secondary":{"usedPercent":"43.5"}}}"#
            )
            #expect(result.primary == nil)
            #expect(result.secondary?.usedPercent == 43.5)
        }

        @Test func extremeDurationsDoNotTrap() throws {
            let result = try quota(
                #"{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":9223372036854775807,"resetsAt":9223372036854775807}}}"#
            )
            let window = CodexQuota.quotaWindow(try #require(result.primary), slot: .primary)
            #expect(window.resetsAt == nil)
            #expect(window.kind == .weekly)
        }

        @Test func rateLimitsMustBeAnObject() {
            #expect(throws: CodexError.appServerUnexpected) { try quota(#"{"other":{}}"#) }
            #expect(throws: CodexError.appServerUnexpected) {
                try CodexAppServerResult.quota(account: nil, rateLimits: nil, now: .reference())
            }
        }

        /// v3 bug 5: a reset-credit object alone is not usage on either path.
        @Test func resetCreditsAloneAreNotUsage() {
            #expect(throws: CodexError.noUsageData) {
                try quota(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":0}}"#)
            }
            #expect(throws: CodexError.noUsageData) {
                try quota(#"{"rateLimits":{"credits":{"balance":"inf"}}}"#)
            }
        }

        @Test(arguments: [#"{"availableCount":[]}"#, "[]", "null"])
        func malformedResetMetadataKeepsQuota(metadata: String) throws {
            let result = try quota(
                #"{"rateLimits":{"primary":{"usedPercent":37}},"rateLimitResetCredits":\#(metadata)}"#
            )
            #expect(result.primary?.usedPercent == 37)
            #expect(result.resetCount == nil)
        }

        @Test func theResetCountStaysWhenRowsAreMalformed() throws {
            let result = try quota(
                #"""
                {"rateLimits":{"primary":{"usedPercent":1}},
                 "rateLimitResetCredits":{"availableCount":3,"credits":"invalid"}}
                """#)
            #expect(result.resetCount == 3)
            #expect(result.resets.isEmpty)
        }

        @Test func expiredRecoveryResetRowsAreDropped() throws {
            let result = try quota(
                #"""
                {"rateLimits":{"primary":{"usedPercent":1}},
                 "rateLimitResetCredits":{"availableCount":2,"credits":[
                   {"title":"Old","expiresAt":1700000000},{"title":" ","expiresAt":1791201600}]}}
                """#)
            #expect(result.resets.map(\.title) == ["Usage reset"])
        }

        @Test func planPrefersRateLimitsThenAccount() throws {
            let fromAccount = try quota(#"{"rateLimits":{"primary":{"usedPercent":1}}}"#)
            #expect(fromAccount.plan == "plus")
            let fromLimits = try quota(
                #"{"rateLimits":{"plan_type":"team","primary":{"usedPercent":1}}}"#)
            #expect(fromLimits.plan == "team")
            let noAccount = try quota(
                #"{"rateLimits":{"primary":{"usedPercent":1}}}"#, account: nil)
            #expect(noAccount.plan == nil)
        }
    }
}

import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCursor

/// Each test gets its own instance, so its own Cursor home, which `deinit` removes.
@Suite final class CursorProviderTests {
    let home: CursorHome
    let keychain = FakeKeychain()
    let owner = CursorFixture.ownerOf(subject: "auth0|user_123")
    let clock = Locked(Date.reference())

    init() throws {
        home = try CursorHome()
    }

    deinit {
        home.remove()
    }

    func provider(_ http: FakeHTTPClient) -> CursorProvider {
        let clock = clock
        return CursorProvider(keychain: keychain, http: http, home: home.url, now: { clock.value })
    }

    func advance(_ seconds: TimeInterval) {
        clock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    func previous(
        owner: AccountOwner? = nil, periodEnd: Date = .reference(.days(10))
    ) -> ProviderUsage {
        let window = QuotaWindow(
            id: "billing", title: "Billing period", kind: .billing, usedPercent: 40,
            resetsAt: periodEnd)
        let spend = Balance(kind: .spend, amount: 12, limit: 20, unit: .currency("USD"))
        let account = AccountUsage(
            id: .default, name: "Cursor", plan: "Pro", windows: [window], balances: [spend],
            observedAt: .reference(-.minutes(10)), owner: owner ?? self.owner)
        return ProviderUsage(provider: .cursor, accounts: [account])
    }

    func account(_ usage: ProviderUsage) throws -> AccountUsage {
        #expect(usage.provider == .cursor)
        #expect(usage.accounts.count == 1)
        return try #require(usage.account(.default))
    }

    @Test func mapsTheUsageResponse() async throws {
        let token = CursorFixture.token()
        try home.write(token: token, membership: "pro")
        let http = FakeHTTPClient(json: CursorFixture.usage)

        let account = try account(try await provider(http).fetch(previous: nil))

        #expect(account.name == "Cursor")
        #expect(account.plan == "Pro")
        #expect(account.observedAt == .reference())
        #expect(account.attemptedAt == .reference())
        #expect(account.owner == owner)
        #expect(!account.isStale)
        #expect(account.issue == nil)
        #expect(account.windows.map(\.id) == ["billing", "auto", "api"])
        #expect(account.windows.map(\.title) == ["Billing period", "Auto + Composer", "API"])
        #expect(account.windows.map(\.kind) == [.billing, .scoped, .scoped])
        #expect(account.windows.map(\.usedPercent) == [62, 10, 100])
        #expect(account.windows.map(\.isBinding) == [true, false, false])
        #expect(
            account.windows.allSatisfy { $0.resetsAt == Date(timeIntervalSince1970: 1_752_592_200) }
        )
        let spend = try #require(account.balance(.spend))
        #expect(spend.amount == Decimal(string: "12.4"))
        #expect(spend.limit == 20)
        #expect(spend.unit == .currency("USD"))

        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.method == .post)
        #expect(request.url == CursorAPI.usageURL)
        #expect(request.headers["Authorization"] == "Bearer \(token)")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Connect-Protocol-Version"] == "1")
        #expect(request.body == Data("{}".utf8))
        #expect(request.retry == .never)
        #expect(request.deadline == .seconds(20))
    }

    @Test func asksForThePlanOnlyWhenCursorStoredNone() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient { request in
            request.url == CursorAPI.planURL
                ? .json(200, #"{"planInfo":{"planName":"pro_plus"}}"#)
                : .json(200, CursorFixture.usage)
        }
        let account = try account(try await provider(http).fetch(previous: nil))
        #expect(account.plan == "Pro+")
        #expect(http.requests.map(\.url) == [CursorAPI.usageURL, CursorAPI.planURL])
        #expect(http.requests.last?.deadline == .seconds(10))
    }

    @Test func planFailureIsSilent() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient { request in
            request.url == CursorAPI.planURL ? .json(500, "") : .json(200, CursorFixture.usage)
        }
        let account = try account(try await provider(http).fetch(previous: nil))
        #expect(account.plan == nil)
        #expect(account.issue == nil)
        #expect(account.windows.first?.usedPercent == 62)
    }

    /// Without a stored plan, the plan that the same login showed is reused, so a refresh sends
    /// one request, not two. After a restart too: a launch sends no plan request.
    @Test func aRecentPlanOfTheSameLoginIsReusedWithoutARequest() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient(json: CursorFixture.usage)
        let account = try account(try await provider(http).fetch(previous: previous()))
        #expect(account.plan == "Pro")
        #expect(http.requests.map(\.url) == [CursorAPI.usageURL])
    }

    /// The plan badge does not disappear because the optional plan request failed.
    @Test func aFailedPlanRequestKeepsThePlanOfTheSameLogin() async throws {
        try home.write(token: CursorFixture.token(expiresAt: .reference(.days(3))))
        let failing = Locked(false)
        let http = FakeHTTPClient { request in
            guard request.url == CursorAPI.planURL else { return .json(200, CursorFixture.usage) }
            return failing.value ? .json(500, "") : .json(200, #"{"planInfo":{"planName":"pro"}}"#)
        }
        let provider = provider(http)
        let first = try await provider.fetch(previous: nil)
        failing.withLock { $0 = true }
        advance(.days(1))

        let account = try account(try await provider.fetch(previous: first))

        #expect(account.plan == "Pro")
        #expect(
            http.requests.map(\.url) == [
                CursorAPI.usageURL, CursorAPI.planURL, CursorAPI.usageURL, CursorAPI.planURL,
            ])
    }

    /// R4-P-02: a plan that the same login keeps showing is asked for again once a day, so a
    /// changed plan shows. A refresh that reuses the plan does not move that day.
    @Test func aKnownPlanIsAskedForAgainAfterADay() async throws {
        try home.write(token: CursorFixture.token(expiresAt: .reference(.days(10))))
        let plan = Locked("pro")
        let http = FakeHTTPClient { request in
            request.url == CursorAPI.planURL
                ? .json(200, #"{"planInfo":{"planName":"\#(plan.value)"}}"#)
                : .json(200, CursorFixture.usage)
        }
        let planRequests = { http.requests.filter { $0.url == CursorAPI.planURL }.count }
        let provider = provider(http)
        var usage = try await provider.fetch(previous: nil)
        var plans = [try account(usage).plan]
        var counts = [planRequests()]
        plan.withLock { $0 = "ultra" }

        for _ in 1...4 {
            advance(.hours(23))
            usage = try await provider.fetch(previous: usage)
            plans.append(try account(usage).plan)
            counts.append(planRequests())
        }

        #expect(plans == ["Pro", "Pro", "Ultra", "Ultra", "Ultra"])
        #expect(counts == [1, 1, 2, 2, 3])
    }

    /// R4-P-02: after a restart, the plan that the same login showed is reused, and its day
    /// starts at the first refresh.
    @Test func afterARestartAKnownPlanIsAskedForAgainAfterADay() async throws {
        try home.write(token: CursorFixture.token(expiresAt: .reference(.days(10))))
        let http = FakeHTTPClient { request in
            request.url == CursorAPI.planURL
                ? .json(200, #"{"planInfo":{"planName":"ultra"}}"#)
                : .json(200, CursorFixture.usage)
        }
        let provider = provider(http)
        advance(.days(3))

        let first = try await provider.fetch(previous: previous())
        advance(.days(1) - 1)
        let second = try await provider.fetch(previous: first)
        #expect(try account(second).plan == "Pro")
        #expect(http.requests.map(\.url) == [CursorAPI.usageURL, CursorAPI.usageURL])
        advance(1)
        let third = try await provider.fetch(previous: second)

        #expect(try account(third).plan == "Ultra")
        #expect(http.requests.map(\.url).suffix(2) == [CursorAPI.usageURL, CursorAPI.planURL])
    }

    /// R3-P-04: a failed or empty plan answer is not asked for again at every refresh. The
    /// same login is asked at most once a day.
    @Test(arguments: [500, 200])
    func aPlanAnswerWithoutAPlanIsAskedAgainOnlyAfterADay(status: Int) async throws {
        try home.write(token: CursorFixture.token(expiresAt: .reference(.days(3))))
        let http = FakeHTTPClient { request in
            request.url == CursorAPI.planURL ? .json(status, "{}") : .json(200, CursorFixture.usage)
        }
        let provider = provider(http)

        let first = try await provider.fetch(previous: nil)
        #expect(try account(first).plan == nil)
        advance(300)
        let second = try await provider.fetch(previous: first)
        #expect(
            http.requests.map(\.url) == [CursorAPI.usageURL, CursorAPI.planURL, CursorAPI.usageURL])
        advance(.days(1))
        _ = try await provider.fetch(previous: second)
        #expect(http.requests.map(\.url).suffix(2) == [CursorAPI.usageURL, CursorAPI.planURL])
    }

    /// R3-P-04: HTTP 429 on the plan request holds the login until its retry time, so the next
    /// refresh sends nothing. The usage of that refresh still shows.
    @Test func aRateLimitedPlanRequestHoldsTheLogin() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient { request in
            request.url == CursorAPI.planURL
                ? .json(429, "", headers: ["Retry-After": "120"])
                : .json(200, CursorFixture.usage)
        }
        let provider = provider(http)

        let first = try await provider.fetch(previous: nil)
        #expect(try account(first).issue == nil)
        #expect(try account(first).windows.first?.usedPercent == 62)
        advance(60)
        let held = try await provider.fetch(previous: first)
        #expect(http.requests.count == 2)
        #expect(try account(held).isStale)
        #expect(try account(held).issue?.retryAt == .reference(120))

        // Another login sends at once.
        try home.write(token: CursorFixture.token(subject: "auth0|other"))
        _ = try await provider.fetch(previous: held)
        #expect(http.requests.map(\.url).suffix(2) == [CursorAPI.usageURL, CursorAPI.planURL])

        // After the retry time the login sends again, without a new plan request that day.
        try home.write(token: CursorFixture.token())
        advance(60)
        let after = try await provider.fetch(previous: held)
        #expect(http.requests.count == 5)
        #expect(http.requests.last?.url == CursorAPI.usageURL)
        #expect(try account(after).issue == nil)
    }

    @Test func thePlanOfAnotherLoginIsNeverReused() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient { request in
            request.url == CursorAPI.planURL ? .json(500, "") : .json(200, CursorFixture.usage)
        }
        let other = previous(owner: CursorFixture.ownerOf(subject: "auth0|other"))
        let account = try account(try await provider(http).fetch(previous: other))
        #expect(account.plan == nil)
        #expect(http.requests.map(\.url) == [CursorAPI.usageURL, CursorAPI.planURL])
    }

    @Test func plansKeepTheirCapitalization() async throws {
        try home.write(token: CursorFixture.token(), membership: "Enterprise Custom")
        let account = try account(
            try await provider(FakeHTTPClient(json: CursorFixture.usage)).fetch(previous: nil))
        #expect(account.plan == "Enterprise Custom")
        #expect(CursorPlan.displayName("PRO") == "Pro")
        #expect(CursorPlan.displayName("  Custom Plan  ") == "Custom Plan")
        #expect(CursorPlan.displayName("pro-plus") == "Pro+")
        #expect(CursorPlan.displayName("TEAM") == "Teams")
        #expect(CursorPlan.displayName(" ") == nil)
    }

    @Test func readsNumbersSentAsStrings() async throws {
        try home.write(token: CursorFixture.token(), membership: "pro")
        let body = """
            {"billingCycleEnd":"2026-10-31T00:00:00.000Z","planUsage":{"totalSpend":"1240","limit":"2000","totalPercentUsed":"62.5","autoPercentUsed":"10"}}
            """
        let account = try account(
            try await provider(FakeHTTPClient(json: body)).fetch(previous: nil))
        #expect(account.windows.map(\.usedPercent) == [62.5, 10])
        #expect(account.windows.first?.resetsAt == DateParsing.iso8601("2026-10-31T00:00:00Z"))
        #expect(account.balance(.spend)?.amount == Decimal(string: "12.4"))
        #expect(account.balance(.spend)?.limit == 20)
    }

    @Test(arguments: ["<html>", "[]", "null", ""])
    func anUnexpectedBodyKeepsTheReadingWithAPlainMessage(body: String) async throws {
        try home.write(token: CursorFixture.token(), membership: "pro")
        let account = try account(
            try await provider(FakeHTTPClient(json: body)).fetch(previous: previous()))
        #expect(account.isStale)
        #expect(
            account.issue?.message
                == "Cursor returned an unexpected response. Claude Meter will try again soon.")
    }

    @Test func transportErrorsTellTheUserWhatHappened() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient { _ in throw HTTPError.offline }
        let account = try account(try await provider(http).fetch(previous: nil))
        #expect(account.issue?.message == "Cannot reach Cursor. Check your internet connection.")
    }

    @Test func cancellationIsNotAFailure() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await provider(http).fetch(previous: previous())
        }
    }

    @Test func signInStatusSendsNoRequest() async throws {
        let http = FakeHTTPClient(json: CursorFixture.usage)
        let provider = provider(http)
        #expect(await provider.signInStatus() == .signedOut)
        try home.write(token: CursorFixture.token())
        #expect(await provider.signInStatus() == .signedIn)
        #expect(http.requests.isEmpty)
    }

    /// A refresh that sent nothing, such as a signed-out or expired one, does not claim that a
    /// request failed.
    @Test func diagnosticsReportOnlyRequestsThatWereSent() async throws {
        let provider = provider(FakeHTTPClient(status: 500, json: ""))
        func lastRequest() async -> String? {
            await provider.diagnostics().first { $0.label == "Last usage request" }?.value
        }
        _ = try await provider.fetch(previous: nil)
        #expect(await lastRequest() == "None")

        try home.write(token: CursorFixture.token())
        _ = try await provider.fetch(previous: nil)
        let failed = await lastRequest()
        #expect(failed?.hasPrefix("Failed at") == true)
        #expect(failed?.contains("HTTP 500") == true)

        try home.write(token: CursorFixture.token(expiresAt: .reference(-60)))
        _ = try await provider.fetch(previous: nil)
        #expect(await lastRequest() == failed)
    }

    @Test func diagnosticsNeverShowTheToken() async throws {
        let token = CursorFixture.token()
        try home.write(token: token, membership: "pro")
        let provider = provider(FakeHTTPClient(json: CursorFixture.usage))
        _ = try await provider.fetch(previous: nil)

        let facts = await provider.diagnostics()

        #expect(facts.contains(DiagnosticFact("State database", "Found")))
        #expect(facts.contains(DiagnosticFact("Access token", "Found in the state database")))
        #expect(facts.contains(DiagnosticFact("Account identity", "Token subject")))
        #expect(
            facts.contains { $0.label == "Last usage request" && $0.value.hasPrefix("Succeeded") })
        #expect(!facts.contains { $0.value.contains(token) || $0.value.contains("alpha@") })
    }
}

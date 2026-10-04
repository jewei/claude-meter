import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderGrok

/// Each test gets its own instance, so its own home folder, which `deinit` removes.
@Suite final class GrokProviderTests {
    /// Captured 2026-07-11 from cli-chat-proxy.grok.com (grok 0.2.93).
    static let liveFixture = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-04T05:57:34.172321+00:00","end":"2026-07-11T05:57:34.172321+00:00"},"creditUsagePercent":36.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":36.0}],"isUnifiedBillingUser":true,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-07-04T05:57:34.172321+00:00","billingPeriodEnd":"2026-07-11T05:57:34.172321+00:00"}}
        """

    private let directory: TemporaryDirectory
    private let token = JWTFixture.token(["sub": "user-1"])
    private let owner = AccountOwner.identity(Digest.sha256(parts: ["grok", "user-1"]))
    private let clock = Locked(Date.reference())

    init() throws {
        directory = try TemporaryDirectory()
    }

    deinit {
        directory.remove()
    }

    private func advance(_ seconds: TimeInterval) {
        clock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    private func signIn(_ key: String? = nil, expiresAt: String = "2099-01-01T00:00:00Z") throws {
        try directory.write(
            #"{"https://auth.x.ai::client":{"key":"\#(key ?? token)","expires_at":"\#(expiresAt)"}}"#,
            to: ".grok/auth.json")
    }

    private func provider(_ http: FakeHTTPClient) -> GrokProvider {
        let clock = clock
        return GrokProvider(http: http, environment: [:], home: directory.url, now: { clock.value })
    }

    private func previous(
        owner: AccountOwner? = nil, periodEnd: Date = .reference(.days(3))
    ) -> ProviderUsage {
        let window = QuotaWindow(
            id: "credits", title: "Weekly", kind: .billing, usedPercent: 20, resetsAt: periodEnd)
        let balances = [
            Balance(kind: .onDemand, amount: 3, unit: .currency("USD")),
            Balance(kind: .prepaid, amount: 5, unit: .currency("USD")),
        ]
        let account = AccountUsage(
            id: .default, name: "Grok", windows: [window], balances: balances,
            observedAt: .reference(-.minutes(10)), owner: owner ?? self.owner)
        return ProviderUsage(provider: .grok, accounts: [account])
    }

    private func account(_ usage: ProviderUsage) throws -> AccountUsage {
        #expect(usage.provider == .grok)
        #expect(usage.accounts.count == 1)
        return try #require(usage.account(.default))
    }

    @Test func sendsTheBearerAndMapsTheLiveFixture() async throws {
        try signIn()
        let http = FakeHTTPClient(json: Self.liveFixture)

        let account = try account(try await provider(http).fetch(previous: nil))

        #expect(account.name == "Grok")
        #expect(account.plan == nil)
        #expect(account.owner == owner)
        #expect(account.observedAt == .reference())
        let window = try #require(account.windows.first)
        #expect(account.windows.count == 1)
        #expect(window.id == "credits")
        #expect(window.title == "Weekly")
        #expect(window.kind == .billing)
        #expect(window.usedPercent == 36)
        #expect(window.isBinding)
        #expect(window.resetsAt.map { $0.timeIntervalSince1970.rounded(.down) } == 1_783_749_454)
        #expect(account.balances.map(\.kind) == [.onDemand, .prepaid])
        #expect(account.balance(.onDemand)?.amount == 0)
        #expect(account.balance(.onDemand)?.limit == nil)
        #expect(account.balance(.prepaid)?.amount == 0)
        #expect(account.balances.allSatisfy { $0.unit == .currency("USD") })

        let request = try #require(http.requests.first)
        #expect(request.method == .get)
        #expect(
            request.url.absoluteString
                == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(request.headers["Authorization"] == "Bearer \(token)")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["User-Agent"] == "ClaudeMeter")
        #expect(request.retry == .transientFailures)
        #expect(request.deadline == .seconds(30))
    }

    @Test(arguments: [#"{"config":{}}"#, "{}", "<html>", #"{"config":[]}"#])
    func aBodyWithoutAPeriodIsUnexpected(body: String) async throws {
        try signIn()
        let account = try account(
            try await provider(FakeHTTPClient(json: body)).fetch(previous: previous()))
        #expect(account.isStale)
        #expect(
            account.issue?.message
                == "Grok returned an unexpected response. Claude Meter will try again soon.")
    }

    /// HTTP 403 means that the login works but has no access, so a new login is not the fix.
    @Test(arguments: [
        (401, "Grok did not accept the sign-in. Open Grok Build and run `grok login`."),
        (403, "Grok denied access to usage data. Check your Grok plan."),
    ])
    func aRejectedSignInKeepsTheReadingWhileTheOwnerIsSignedIn(status: Int, message: String)
        async throws
    {
        try signIn()
        let account = try account(
            try await provider(FakeHTTPClient(status: status, json: "")).fetch(previous: previous())
        )
        #expect(account.isStale)
        #expect(account.issue?.message == message)
        #expect(account.issue?.needsAction == true)
    }

    @Test func anExpiredTokenIsNeverSent() async throws {
        try signIn(expiresAt: "2026-10-04T11:59:00Z")
        let http = FakeHTTPClient(json: Self.liveFixture)

        let account = try account(try await provider(http).fetch(previous: previous()))

        #expect(http.requests.isEmpty)
        #expect(account.isStale)
        #expect(account.issue?.message == "Your Grok sign-in expired. Open Grok Build to renew it.")
        #expect(account.issue?.needsAction == true)
    }

    @Test func signingOutDropsTheReading() async throws {
        let provider = provider(FakeHTTPClient(json: Self.liveFixture))
        #expect(await provider.reconcile(previous()) == nil)
        let account = try account(try await provider.fetch(previous: previous()))
        #expect(!account.hasObservation)
        #expect(account.issue?.needsAction == true)
    }

    @Test func reconcileKeepsOnlyTheSignedInOwner() async throws {
        try signIn()
        let provider = provider(FakeHTTPClient(json: Self.liveFixture))
        #expect(await provider.reconcile(previous()) == previous())
        let other = previous(owner: .identity(Digest.sha256(parts: ["grok", "user-2"])))
        #expect(await provider.reconcile(other) == nil)
    }

    /// The CLI renews its opaque key, but the email stays, so the reading survives the
    /// renewal, a failure right after it, and a restart (an identity owner is saved).
    @Test func aRenewedOpaqueKeyKeepsTheReading() async throws {
        let entry = { (key: String) in
            #"{"https://auth.x.ai::c":{"key":"\#(key)","email":"alpha@example.com"}}"#
        }
        try directory.write(entry("oidc-first"), to: ".grok/auth.json")
        let usage = try await provider(FakeHTTPClient(json: Self.liveFixture)).fetch(previous: nil)
        #expect(try account(usage).owner?.isPersistable == true)

        try directory.write(entry("oidc-renewed"), to: ".grok/auth.json")
        let provider = provider(FakeHTTPClient(status: 503, json: ""))
        #expect(await provider.reconcile(usage) == usage)
        let kept = try account(try await provider.fetch(previous: usage))

        #expect(kept.isStale)
        #expect(kept.observedAt == .reference())
        #expect(kept.owner == (try account(usage)).owner)
    }

    @Test func anUnreadableFileKeepsTheReading() async throws {
        try directory.write("{", to: ".grok/auth.json")
        let http = FakeHTTPClient(json: Self.liveFixture)
        let provider = provider(http)

        #expect(await provider.reconcile(previous()) == previous())
        let account = try account(try await provider.fetch(previous: previous()))

        #expect(account.isStale)
        #expect(http.requests.isEmpty)
    }

    /// Nothing is sent before the server's retry time, so the countdown on the card is true.
    @Test func aRateLimitHoldsEveryRequestUntilItsRetryTime() async throws {
        try signIn()
        let http = FakeHTTPClient(status: 429, json: "", headers: ["Retry-After": "120"])
        let provider = provider(http)

        let limited = try await provider.fetch(previous: previous())
        #expect(try account(limited).issue?.retryAt == .reference(120))
        advance(60)
        let held = try await provider.fetch(previous: limited)

        #expect(http.requests.count == 1)
        let account = try account(held)
        #expect(account.isStale)
        #expect(account.windows.first?.usedPercent == 20)
        #expect(account.issue?.retryAt == .reference(120))

        advance(61)
        _ = try await provider.fetch(previous: held)
        #expect(http.requests.count == 2)
    }

    /// After the period ends, a stale card must not show the old period's on-demand spend
    /// beside an unknown percentage. The prepaid balance is not tied to a period.
    @Test func aStaleReadingDropsItsOnDemandSpendAfterThePeriodEnds() async throws {
        try signIn()
        let http = FakeHTTPClient(status: 503, json: "")

        let inPeriod = try account(try await provider(http).fetch(previous: previous()))
        let after = try account(
            try await provider(http).fetch(previous: previous(periodEnd: .reference(-60))))

        #expect(inPeriod.balance(.onDemand)?.amount == 3)
        #expect(after.isStale)
        #expect(after.windows.first?.usedPercent == nil)
        #expect(after.balance(.onDemand) == nil)
        #expect(after.balance(.prepaid)?.amount == 5)
    }

    @Test func serverErrorsKeepTheReading() async throws {
        try signIn()
        let account = try account(
            try await provider(FakeHTTPClient(status: 503, json: "")).fetch(previous: previous()))
        #expect(account.isStale)
        #expect(
            account.issue?.message
                == "The Grok usage request failed (HTTP 503). Claude Meter will try again soon.")
        #expect(account.issue?.needsAction == false)
    }

    @Test func aLoginChangeDuringTheRequestDiscardsTheResponse() async throws {
        try signIn()
        let directory = directory
        let http = FakeHTTPClient { _ in
            try directory.write(
                #"{"https://auth.x.ai::client":{"key":"\#(JWTFixture.token(["sub": "user-2"]))"}}"#,
                to: ".grok/auth.json")
            return .json(200, Self.liveFixture)
        }

        let account = try account(try await provider(http).fetch(previous: previous()))

        #expect(!account.hasObservation)
        #expect(account.owner == .identity(Digest.sha256(parts: ["grok", "user-2"])))
        #expect(account.issue == GrokFailure.signInChanged.issue)
    }

    @Test func cancellationIsNotAFailure() async throws {
        try signIn()
        let http = FakeHTTPClient { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await provider(http).fetch(previous: previous())
        }
    }

    @Test func signInStatusSendsNoRequest() async throws {
        let http = FakeHTTPClient(json: Self.liveFixture)
        let provider = provider(http)
        #expect(await provider.signInStatus() == .signedOut)
        try signIn()
        #expect(await provider.signInStatus() == .signedIn)
        #expect(http.requests.isEmpty)
    }

    /// A refresh that sent nothing, such as a signed-out or expired one, does not claim that a
    /// request failed.
    @Test func diagnosticsReportOnlyRequestsThatWereSent() async throws {
        let provider = provider(FakeHTTPClient(status: 503, json: ""))
        func lastRequest() async -> String? {
            await provider.diagnostics().first { $0.label == "Last usage request" }?.value
        }
        _ = try await provider.fetch(previous: nil)
        #expect(await lastRequest() == "None")

        try signIn()
        _ = try await provider.fetch(previous: nil)
        let failed = await lastRequest()
        #expect(failed?.hasPrefix("Failed at") == true)
        #expect(failed?.contains("HTTP 503") == true)

        try signIn(expiresAt: "2026-10-04T11:00:00Z")
        _ = try await provider.fetch(previous: nil)
        #expect(await lastRequest() == failed)
    }

    @Test func diagnosticsNeverShowTheToken() async throws {
        try signIn()
        let provider = provider(FakeHTTPClient(json: Self.liveFixture))
        _ = try await provider.fetch(previous: nil)

        let facts = await provider.diagnostics()

        #expect(facts.contains(DiagnosticFact("GROK_HOME", "Not set")))
        #expect(facts.contains(DiagnosticFact("Account identity", "Token subject")))
        #expect(
            facts.contains { $0.label == "Last usage request" && $0.value.hasPrefix("Succeeded") })
        #expect(!facts.contains { $0.value.contains(token) })
    }
}

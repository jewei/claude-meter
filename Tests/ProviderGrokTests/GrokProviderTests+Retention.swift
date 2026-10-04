import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderGrok

/// Retention: which failures keep the last observation, for whom, and for how long.
extension GrokProviderTests {
    /// A key that expires in less than 30 s counts as expired, so it never comes back as a
    /// 401 with the harsher message.
    @Test(arguments: ["2026-10-04T11:59:00Z", "2026-10-04T12:00:10Z"])
    func anExpiredTokenIsNeverSent(expiresAt: String) async throws {
        try signIn(expiresAt: expiresAt)
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

    @Test func aSignOutDuringTheRequestDropsTheReading() async throws {
        try signIn()
        let directory = directory
        let http = FakeHTTPClient { _ in
            try FileManager.default.removeItem(at: directory.path(".grok/auth.json"))
            return .json(200, Self.liveFixture)
        }

        let account = try account(try await provider(http).fetch(previous: previous()))

        #expect(!account.hasObservation)
        #expect(account.issue == GrokFailure.signedOut.issue)
    }

    /// An unreadable file after the response proves nothing, so the response stands.
    @Test func anUnreadableFileAfterTheResponseKeepsTheResponse() async throws {
        try signIn()
        let directory = directory
        let http = FakeHTTPClient { _ in
            try directory.write("{", to: ".grok/auth.json")
            return .json(200, Self.liveFixture)
        }

        let account = try account(try await provider(http).fetch(previous: previous()))

        #expect(account.observedAt == .reference())
        #expect(account.issue == nil)
        #expect(account.owner == owner)
    }
}

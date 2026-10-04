import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCursor

/// Retention: which failures keep the last observation, for whom, and for how long.
extension CursorProviderTests {
    /// A token that expires in less than 30 s counts as expired, so it never comes back as a
    /// 401 with the harsher message.
    @Test(arguments: [-60.0, 10.0])
    func anExpiredTokenIsNeverSent(expiresIn: TimeInterval) async throws {
        try home.write(token: CursorFixture.token(expiresAt: .reference(expiresIn)))
        let http = FakeHTTPClient(json: CursorFixture.usage)

        let account = try account(try await provider(http).fetch(previous: previous()))

        #expect(http.requests.isEmpty)
        #expect(account.isStale)
        #expect(account.windows.first?.usedPercent == 40)
        #expect(account.issue?.message == "Your Cursor session expired. Open Cursor to renew it.")
        #expect(account.issue?.needsAction == true)
        #expect(account.attemptedAt == .reference())
    }

    @Test(arguments: [401, 403])
    func aRejectedSessionKeepsTheReadingWhileTheOwnerIsSignedIn(status: Int) async throws {
        try home.write(token: CursorFixture.token())
        let provider = provider(FakeHTTPClient(status: status, json: "{}"))

        let kept = try account(try await provider.fetch(previous: previous()))
        #expect(kept.isStale)
        #expect(kept.observedAt == .reference(-.minutes(10)))
        #expect(kept.issue?.needsAction == true)

        let fresh = try account(try await provider.fetch(previous: nil))
        #expect(!fresh.hasObservation)
        #expect(fresh.issue == kept.issue)
        #expect(fresh.owner == owner)
    }

    @Test func signingOutDropsTheReading() async throws {
        let provider = provider(FakeHTTPClient(json: CursorFixture.usage))

        #expect(await provider.reconcile(previous()) == nil)
        let account = try account(try await provider.fetch(previous: previous()))

        #expect(!account.hasObservation)
        #expect(account.issue?.message == "Cursor is not signed in. Open Cursor and sign in.")
        #expect(account.issue?.needsAction == true)
    }

    /// A busy database never hands the refresh to another login's Keychain token.
    @Test func aBusyDatabaseKeepsTheReadingAndSendsNoOtherLogin() async throws {
        try home.write(
            ["cursorAuth/accessToken": .text(CursorFixture.token())], journalMode: "DELETE")
        keychain.store(CursorFixture.token(subject: "auth0|other"), service: "cursor-access-token")
        let lock = try home.lockExclusively()
        defer { home.unlock(lock) }
        let http = FakeHTTPClient(json: CursorFixture.usage)
        let provider = provider(http)

        #expect(await provider.reconcile(previous()) == previous())
        let account = try account(try await provider.fetch(previous: previous()))

        #expect(account.isStale)
        #expect(account.owner == owner)
        #expect(account.windows.first?.usedPercent == 40)
        #expect(account.issue == CursorFailure.credentialsBusy.issue)
        #expect(account.issue?.needsAction == false)
        #expect(http.requests.isEmpty)
        #expect(keychain.readServices.isEmpty)
    }

    @Test func reconcileKeepsOnlyTheSignedInOwnerAndSendsNothing() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient(json: CursorFixture.usage)
        let provider = provider(http)
        #expect(await provider.reconcile(nil) == nil)
        #expect(await provider.reconcile(previous()) == previous())
        let other = previous(owner: CursorFixture.ownerOf(subject: "auth0|other"))
        #expect(await provider.reconcile(other) == nil)
        #expect(http.requests.isEmpty)
    }

    @Test func aSignOutDuringTheRequestDropsTheReading() async throws {
        try home.write(token: CursorFixture.token())
        let home = home
        let http = FakeHTTPClient { _ in
            try FileManager.default.removeItem(at: home.database)
            return .json(200, CursorFixture.usage)
        }

        let account = try account(try await provider(http).fetch(previous: previous()))

        #expect(!account.hasObservation)
        #expect(account.issue == CursorFailure.signedOut.issue)
    }

    /// An unreadable login after the response proves nothing, so the response stands.
    @Test func anUnreadableLoginAfterTheResponseKeepsTheResponse() async throws {
        try home.write(token: CursorFixture.token(), membership: "pro")
        let home = home
        let http = FakeHTTPClient { _ in
            try home.directory.write(
                "not a database",
                to: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            return .json(200, CursorFixture.usage)
        }

        let account = try account(try await provider(http).fetch(previous: previous()))

        #expect(account.observedAt == .reference())
        #expect(account.issue == nil)
        #expect(account.owner == owner)
    }

    @Test func aLoginChangeDuringTheRequestDiscardsTheResponse() async throws {
        keychain.store(CursorFixture.token(), service: "cursor-access-token")
        let keychain = keychain
        let http = FakeHTTPClient { _ in
            keychain.store(
                CursorFixture.token(subject: "auth0|other"), service: "cursor-access-token")
            return .json(200, CursorFixture.usage)
        }

        let account = try account(try await provider(http).fetch(previous: previous()))

        #expect(!account.hasObservation)
        #expect(account.owner == CursorFixture.ownerOf(subject: "auth0|other"))
        #expect(
            account.issue?.message
                == "The Cursor account changed during the refresh. Refresh again to show the new account."
        )
    }

    @Test func disabledUsageDropsTheReading() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient(json: #"{"enabled":false}"#)
        let account = try account(try await provider(http).fetch(previous: previous()))
        #expect(!account.hasObservation)
        #expect(account.issue?.needsAction == true)
        #expect(http.requests.count == 1)
    }

    /// After the billing period ends, a stale card must not show the old period's spend beside
    /// an unknown percentage.
    @Test func aStaleReadingDropsItsSpendAfterThePeriodEnds() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient(status: 500, json: "")

        let inPeriod = try account(try await provider(http).fetch(previous: previous()))
        let after = try account(
            try await provider(http).fetch(previous: previous(periodEnd: .reference(-60))))

        #expect(inPeriod.isStale)
        #expect(inPeriod.balance(.spend)?.amount == 12)
        #expect(after.isStale)
        #expect(after.windows.first?.usedPercent == nil)
        #expect(after.balance(.spend) == nil)
        #expect(after.plan == "Pro")
    }

    @Test func serverErrorsKeepTheReading() async throws {
        try home.write(token: CursorFixture.token())
        let account = try account(
            try await provider(FakeHTTPClient(status: 500, json: "")).fetch(previous: previous()))
        #expect(account.isStale)
        #expect(
            account.issue?.message
                == "The Cursor request failed (HTTP 500). Claude Meter will try again soon.")
        #expect(account.issue?.needsAction == false)
    }

    @Test func rateLimitsCarryTheRetryTime() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient(status: 429, json: "", headers: ["Retry-After": "120"])
        let account = try account(try await provider(http).fetch(previous: nil))
        #expect(account.issue?.retryAt == .reference(120))
    }

    /// Nothing is sent before the server's retry time, so the countdown on the card is true.
    @Test func aRateLimitHoldsEveryRequestUntilItsRetryTime() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient(status: 429, json: "", headers: ["Retry-After": "120"])
        let provider = provider(http)

        let limited = try await provider.fetch(previous: previous())
        #expect(http.requests.count == 1)
        advance(60)
        let held = try await provider.fetch(previous: limited)

        #expect(http.requests.count == 1)
        let account = try account(held)
        #expect(account.isStale)
        #expect(account.windows.first?.usedPercent == 40)
        #expect(account.issue?.retryAt == .reference(120))

        advance(61)
        _ = try await provider.fetch(previous: held)
        #expect(http.requests.count == 2)
    }

    @Test func aRateLimitOfAnotherLoginHoldsNothing() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient(status: 429, json: "", headers: ["Retry-After": "120"])
        let limited = try await provider(http).fetch(previous: nil)
        try home.write(token: CursorFixture.token(subject: "auth0|other"))

        _ = try await provider(http).fetch(previous: limited)

        #expect(http.requests.count == 2)
    }
}

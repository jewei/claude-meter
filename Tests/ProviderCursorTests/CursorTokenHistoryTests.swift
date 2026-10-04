import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCursor

/// Each test gets its own instance, so its own Cursor home, which `deinit` removes.
@Suite final class CursorTokenHistoryTests {
    private static let header = CursorFixture.csvHeader

    private let home: CursorHome
    private let keychain = FakeKeychain()
    private let calendar = Calendar.fixed("UTC")

    init() throws {
        home = try CursorHome()
    }

    deinit {
        home.remove()
    }

    private func source(_ http: FakeHTTPClient) -> CursorTokenHistory {
        CursorTokenHistory(keychain: keychain, http: http, home: home.url, calendar: calendar)
    }

    private func range() throws -> DateInterval {
        try #require(TokenPeriod.lastSevenDays.interval(at: .reference(), calendar: calendar))
    }

    private func tokens(_ history: TokenHistory, _ period: TokenPeriod) -> Int64? {
        history.tokens(in: period, now: .reference(), calendar: calendar)
    }

    private func providerError(_ body: () async throws -> ProviderTokenHistory) async
        -> ProviderError?
    {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? ProviderError
        }
    }

    @Test func requestsSevenDaysWithTheSessionCookieOnly() async throws {
        let token = CursorFixture.token()
        try home.write(token: token)
        let http = FakeHTTPClient(json: Self.header)

        let result = try await source(http).history(now: .reference(), previous: nil)

        let request = try #require(http.requests.first)
        let components = try #require(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let start = Int64(try range().start.timeIntervalSince1970 * 1000)
        #expect(components.host == "cursor.com")
        #expect(components.path == "/api/dashboard/export-usage-events-csv")
        #expect(
            components.queryItems == [
                URLQueryItem(name: "startDate", value: String(start)),
                URLQueryItem(name: "endDate", value: "1791115200000"),
                URLQueryItem(name: "strategy", value: "tokens"),
            ])
        #expect(request.method == .get)
        #expect(request.headers["Cookie"] == "WorkosCursorSessionToken=user_123%3A%3A\(token)")
        #expect(request.headers["Accept"] == "text/csv")
        #expect(request.headers["Origin"] == "https://cursor.com")
        #expect(request.headers["Authorization"] == nil)
        #expect(request.retry == .never)
        #expect(request.deadline == .seconds(10))
        #expect(result.provider == .cursor)
        #expect(result.source == .account)
        #expect(Array(result.accounts.keys) == [.default])
        #expect(result.coverageStart == (try range().start))
        #expect(result.timeZoneID == calendar.timeZone.identifier)
        #expect(tokens(result.history(for: .default), .today) == 0)
    }

    /// A time zone change applies to the next read. A history labeled with the old zone would
    /// stay unknown and make every refresh export again.
    @Test func eachReadUsesTheTimeZoneOfThatMoment() async throws {
        try home.write(token: CursorFixture.token())
        let zone = Locked(Calendar.fixed("UTC"))
        let http = FakeHTTPClient(json: Self.header)
        let source = CursorTokenHistory(
            keychain: keychain, http: http, home: home.url, calendar: { zone.value })

        let first = try await source.history(now: .reference(), previous: nil)
        zone.withLock { $0 = .fixed("Asia/Tokyo") }
        let second = try await source.history(now: .reference(), previous: nil)

        let tokyo = Calendar.fixed("Asia/Tokyo")
        let range = try #require(
            TokenPeriod.lastSevenDays.interval(at: .reference(), calendar: tokyo))
        #expect(first.timeZoneID == calendar.timeZone.identifier)
        #expect(second.timeZoneID == "Asia/Tokyo")
        #expect(second.coverageStart == range.start)
        let history = second.history(for: .default)
        #expect(history.timeZoneID == "Asia/Tokyo")
        #expect(history.tokens(in: .today, now: .reference(), calendar: tokyo) == 0)
        let request = try #require(http.requests.last)
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let start = components?.queryItems?.first { $0.name == "startDate" }?.value
        #expect(start == String(Int64(range.start.timeIntervalSince1970 * 1000)))
    }

    /// `auth0|` has an empty user ID after the last `|`; it must not become the user `auth0`.
    @Test(arguments: [
        "opaque token!", JWTFixture.token(["exp": 1_791_200_000]),
        CursorFixture.token(subject: "auth0|"), CursorFixture.token(subject: "auth0|user 1"),
    ])
    func aTokenOfUnexpectedFormatIsNotCalledExpired(token: String) async throws {
        keychain.store(token, service: "cursor-access-token")
        let http = FakeHTTPClient(json: Self.header)

        let error = await providerError {
            try await source(http).history(now: .reference(), previous: nil)
        }

        #expect(
            error?.issue.message
                == "The Cursor sign-in token has an unexpected format. Update Claude Meter if this continues."
        )
        #expect(http.requests.isEmpty)
    }

    @Test func aLoginChangeDuringTheRequestRejectsTheResult() async throws {
        let keychain = keychain
        keychain.store(CursorFixture.token(), service: "cursor-access-token")
        let http = FakeHTTPClient { _ in
            keychain.store(
                CursorFixture.token(subject: "auth0|other"), service: "cursor-access-token")
            return .json(200, Self.header)
        }

        let error = await providerError {
            try await source(http).history(now: .reference(), previous: nil)
        }

        #expect(error?.keepsLastReading == false)
        #expect(error?.issue == CursorFailure.signInChanged.issue)
    }

    @Test func failuresKeepTheHeldHistoryOnlyForItsLogin() async throws {
        keychain.store(CursorFixture.token(), service: "cursor-access-token")
        let status = Locked(200)
        let http = FakeHTTPClient { _ in .json(status.value, Self.header) }
        let source = source(http)
        let held = try await source.history(now: .reference(), previous: nil)
        #expect(held.owner != nil)

        status.withLock { $0 = 500 }
        let serverError = await providerError {
            try await source.history(now: .reference(), previous: held)
        }
        #expect(serverError?.keepsLastReading == true)
        #expect(serverError?.issue.needsAction == false)

        status.withLock { $0 = 401 }
        let rejected = await providerError {
            try await source.history(now: .reference(), previous: held)
        }
        #expect(rejected?.keepsLastReading == true)
        #expect(rejected?.issue.needsAction == true)

        keychain.store(CursorFixture.token(subject: "auth0|other"), service: "cursor-access-token")
        status.withLock { $0 = 500 }
        let otherLogin = await providerError {
            try await source.history(now: .reference(), previous: held)
        }
        #expect(otherLogin?.keepsLastReading == false)

        let nothingHeld = await providerError {
            try await source.history(now: .reference(), previous: nil)
        }
        #expect(nothingHeld?.keepsLastReading == false)
    }

    @Test func reconcileDropsTheHistoryOfAnotherLogin() async throws {
        keychain.store(CursorFixture.token(), service: "cursor-access-token")
        let source = source(FakeHTTPClient(json: Self.header))
        let held = try await source.history(now: .reference(), previous: nil)
        #expect(await source.reconcile(held) == held)
        #expect(await source.reconcile(nil) == nil)

        keychain.store(CursorFixture.token(subject: "auth0|other"), service: "cursor-access-token")
        #expect(await source.reconcile(held) == nil)

        try keychain.deletePassword(service: "cursor-access-token", account: "user")
        #expect(await source.reconcile(held) == nil)
    }

    /// Retention follows the login that is signed in after the request, as for quota.
    @Test func aLoginChangeKeepsOnlyTheHistoryOfTheLoginSignedInAfterIt() async throws {
        let first = CursorFixture.token()
        let other = CursorFixture.token(subject: "auth0|other")
        let keychain = keychain
        let switchTo = Locked<String?>(nil)
        let http = FakeHTTPClient { _ in
            if let token = switchTo.value { keychain.store(token, service: "cursor-access-token") }
            return .json(200, Self.header)
        }
        let source = source(http)
        keychain.store(first, service: "cursor-access-token")
        let held = try await source.history(now: .reference(), previous: nil)

        // The app holds the first login's history, and the other login signs in mid-request.
        switchTo.withLock { $0 = other }
        let toOther = await providerError {
            try await source.history(now: .reference(), previous: held)
        }
        #expect(toOther?.issue == CursorFailure.signInChanged.issue)
        #expect(toOther?.keepsLastReading == false)

        // The first login signs in again mid-request, and the held history is its own.
        switchTo.withLock { $0 = first }
        let back = await providerError {
            try await source.history(now: .reference(), previous: held)
        }
        #expect(back?.issue == CursorFailure.signInChanged.issue)
        #expect(back?.keepsLastReading == true)
    }

    /// The HTTP client's 8 MiB limit, not the row limit, bounds a large export in practice.
    /// The failure says so instead of calling the response unexpected.
    @Test func anExportAboveTheResponseLimitSaysWhereToLook() async throws {
        keychain.store(CursorFixture.token(), service: "cursor-access-token")
        let http = FakeHTTPClient { _ in throw HTTPError.responseTooLarge(limit: 8 * 1024 * 1024) }

        let error = await providerError {
            try await source(http).history(now: .reference(), previous: nil)
        }

        #expect(
            error?.issue.message
                == "Cursor sent more usage records than Claude Meter can count. Check your usage in the Cursor dashboard."
        )
    }

    /// The app's 20 s history limit covers `reconcile` and the read: the credential read of
    /// `reconcile`, the reads before and after the export, and the export, with at least 4 s
    /// left to parse.
    @Test func threeCredentialReadsAndTheExportFitTheHistoryLimit() {
        let reconcileRead = CursorCredentialStore.historyReadTimeout
        let readBefore = CursorCredentialStore.historyReadTimeout
        let readAfter = CursorCredentialStore.historyReadTimeout
        let worstCase = reconcileRead + readBefore + CursorAPI.exportDeadline + readAfter
        #expect(worstCase <= .seconds(16))
    }

    /// Nothing is sent before the server's retry time.
    @Test func aRateLimitHoldsTheExportUntilItsRetryTime() async throws {
        keychain.store(CursorFixture.token(), service: "cursor-access-token")
        let http = FakeHTTPClient(status: 429, json: "", headers: ["Retry-After": "120"])
        let source = source(http)

        let limited = await providerError {
            try await source.history(now: .reference(), previous: nil)
        }
        let held = await providerError {
            try await source.history(now: .reference(60), previous: nil)
        }

        #expect(limited?.issue.retryAt == .reference(120))
        #expect(held?.issue.retryAt == .reference(120))
        #expect(http.requests.count == 1)
        _ = await providerError { try await source.history(now: .reference(121), previous: nil) }
        #expect(http.requests.count == 2)
    }

    /// The hold of one login never stops the export of another login, and it stays for its
    /// own login while another login reads.
    @Test func aRateLimitHoldsOnlyTheLoginThatGotIt() async throws {
        let first = CursorFixture.token(expiresAt: .reference(.days(1)))
        let other = CursorFixture.token(subject: "auth0|other", expiresAt: .reference(.days(1)))
        let status = Locked(429)
        let http = FakeHTTPClient { _ in
            .json(status.value, Self.header, headers: ["Retry-After": "120"])
        }
        let source = source(http)
        keychain.store(first, service: "cursor-access-token")
        let limited = await providerError {
            try await source.history(now: .reference(), previous: nil)
        }
        #expect(limited?.issue.retryAt == .reference(120))

        keychain.store(other, service: "cursor-access-token")
        status.withLock { $0 = 200 }
        _ = try await source.history(now: .reference(10), previous: nil)
        #expect(http.requests.count == 2)

        keychain.store(first, service: "cursor-access-token")
        let held = await providerError {
            try await source.history(now: .reference(20), previous: nil)
        }
        #expect(held?.issue.retryAt == .reference(120))
        #expect(http.requests.count == 2)
    }

    /// A wrong `Retry-After` cannot stop the export for more than one hour.
    @Test func aRateLimitHoldsTheExportAtMostOneHour() async throws {
        keychain.store(
            CursorFixture.token(expiresAt: .reference(.days(1))), service: "cursor-access-token")
        let http = FakeHTTPClient(status: 429, json: "", headers: ["Retry-After": "86400"])
        let source = source(http)

        let limited = await providerError {
            try await source.history(now: .reference(), previous: nil)
        }
        _ = await providerError {
            try await source.history(now: .reference(.hours(1) - 1), previous: nil)
        }
        #expect(limited?.issue.retryAt == .reference(.hours(1)))
        #expect(http.requests.count == 1)
        _ = await providerError {
            try await source.history(now: .reference(.hours(1)), previous: nil)
        }
        #expect(http.requests.count == 2)
    }

    @Test func signingOutClearsTheHistory() async throws {
        let error = await providerError {
            try await source(FakeHTTPClient(json: Self.header)).history(
                now: .reference(), previous: nil)
        }
        #expect(error?.keepsLastReading == false)
        #expect(error?.issue.needsAction == true)
    }

    @Test func aBusyDatabaseKeepsTheHistory() async throws {
        try home.write(
            ["cursorAuth/accessToken": .text(CursorFixture.token())], journalMode: "DELETE")
        let lock = try home.lockExclusively()
        defer { home.unlock(lock) }
        let http = FakeHTTPClient(json: Self.header)
        // The app holds this login's history; a busy database proves no other login.
        let held = ProviderTokenHistory(
            provider: .cursor, source: .account, accounts: [:], coverageStart: .reference(),
            observedAt: .reference(), timeZoneID: "UTC", owner: .identity("cursor-owner"))

        let error = await providerError {
            try await source(http).history(now: .reference(), previous: held)
        }

        #expect(error?.keepsLastReading == true)
        #expect(error?.issue == CursorFailure.credentialsBusy.issue)
        #expect(http.requests.isEmpty)
    }

    @Test func anExpiredTokenIsNeverSent() async throws {
        try home.write(token: CursorFixture.token(expiresAt: .reference(-1)))
        let http = FakeHTTPClient(json: Self.header)

        let error = await providerError {
            try await source(http).history(now: .reference(), previous: nil)
        }

        #expect(error?.issue == CursorFailure.sessionExpired.issue)
        #expect(http.requests.isEmpty)
    }
}

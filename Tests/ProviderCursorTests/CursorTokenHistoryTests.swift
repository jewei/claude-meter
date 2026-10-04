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

        let result = try await source(http).history(now: .reference())

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
        #expect(request.deadline == .seconds(12))
        #expect(result.provider == .cursor)
        #expect(result.source == .account)
        #expect(Array(result.accounts.keys) == [.default])
        #expect(result.coverageStart == (try range().start))
        #expect(result.timeZoneID == calendar.timeZone.identifier)
        #expect(tokens(result.history(for: .default), .today) == 0)
    }

    @Test(arguments: ["opaque token!", JWTFixture.token(["exp": 1_791_200_000])])
    func aTokenOfUnexpectedFormatIsNotCalledExpired(token: String) async throws {
        keychain.store(token, service: "cursor-access-token")
        let http = FakeHTTPClient(json: Self.header)

        let error = await providerError { try await source(http).history(now: .reference()) }

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

        let error = await providerError { try await source(http).history(now: .reference()) }

        #expect(error?.keepsLastReading == false)
        #expect(error?.issue == CursorFailure.signInChanged.issue)
    }

    @Test func failuresKeepTheHistoryOnlyForTheSameLogin() async throws {
        keychain.store(CursorFixture.token(), service: "cursor-access-token")
        let status = Locked(200)
        let http = FakeHTTPClient { _ in .json(status.value, Self.header) }
        let source = source(http)
        _ = try await source.history(now: .reference())

        status.withLock { $0 = 500 }
        let serverError = await providerError { try await source.history(now: .reference()) }
        #expect(serverError?.keepsLastReading == true)
        #expect(serverError?.issue.needsAction == false)

        status.withLock { $0 = 401 }
        let rejected = await providerError { try await source.history(now: .reference()) }
        #expect(rejected?.keepsLastReading == true)
        #expect(rejected?.issue.needsAction == true)

        keychain.store(CursorFixture.token(subject: "auth0|other"), service: "cursor-access-token")
        status.withLock { $0 = 500 }
        let otherLogin = await providerError { try await source.history(now: .reference()) }
        #expect(otherLogin?.keepsLastReading == false)
    }

    @Test func signingOutClearsTheHistory() async throws {
        let error = await providerError {
            try await source(FakeHTTPClient(json: Self.header)).history(now: .reference())
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

        let error = await providerError { try await source(http).history(now: .reference()) }

        #expect(error?.keepsLastReading == true)
        #expect(error?.issue == CursorFailure.credentialsBusy.issue)
        #expect(http.requests.isEmpty)
    }

    @Test func anExpiredTokenIsNeverSent() async throws {
        try home.write(token: CursorFixture.token(expiresAt: .reference(-1)))
        let http = FakeHTTPClient(json: Self.header)

        let error = await providerError { try await source(http).history(now: .reference()) }

        #expect(error?.issue == CursorFailure.sessionExpired.issue)
        #expect(http.requests.isEmpty)
    }
}

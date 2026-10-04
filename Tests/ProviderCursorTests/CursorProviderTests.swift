import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCursor

/// Each test gets its own instance, so its own Cursor home, which `deinit` removes.
@Suite final class CursorProviderTests {
    private let home: CursorHome
    private let keychain = FakeKeychain()
    private let owner = CursorFixture.ownerOf(subject: "auth0|user_123")

    init() throws {
        home = try CursorHome()
    }

    deinit {
        home.remove()
    }

    private func provider(_ http: FakeHTTPClient) -> CursorProvider {
        CursorProvider(keychain: keychain, http: http, home: home.url, now: { .reference() })
    }

    private func previous(owner: AccountOwner? = nil) -> ProviderUsage {
        let window = QuotaWindow(
            id: "billing", title: "Billing period", kind: .billing, usedPercent: 40,
            resetsAt: .reference(.days(10)))
        let account = AccountUsage(
            id: .default, name: "Cursor", plan: "Pro", windows: [window],
            observedAt: .reference(-.minutes(10)), owner: owner ?? self.owner)
        return ProviderUsage(provider: .cursor, accounts: [account])
    }

    private func account(_ usage: ProviderUsage) throws -> AccountUsage {
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

    @Test func anExpiredTokenIsNeverSent() async throws {
        try home.write(token: CursorFixture.token(expiresAt: .reference(-60)))
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

    @Test func reconcileKeepsOnlyTheSignedInOwner() async throws {
        try home.write(token: CursorFixture.token())
        let provider = provider(FakeHTTPClient(json: CursorFixture.usage))
        #expect(await provider.reconcile(nil) == nil)
        #expect(await provider.reconcile(previous()) == previous())
        let other = previous(owner: CursorFixture.ownerOf(subject: "auth0|other"))
        #expect(await provider.reconcile(other) == nil)
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

    @Test func disabledUsageDropsTheReading() async throws {
        try home.write(token: CursorFixture.token())
        let http = FakeHTTPClient(json: #"{"enabled":false}"#)
        let account = try account(try await provider(http).fetch(previous: previous()))
        #expect(!account.hasObservation)
        #expect(account.issue?.needsAction == true)
        #expect(http.requests.count == 1)
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

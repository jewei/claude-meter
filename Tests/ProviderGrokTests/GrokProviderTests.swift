import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderGrok

// Serialized: parallel reads can pass `BlockingIO.capacity`, which rejects work at once.
@Suite struct GrokProviderTests {
    /// Captured 2026-07-11 from cli-chat-proxy.grok.com (grok 0.2.93).
    static let liveFixture = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-04T05:57:34.172321+00:00","end":"2026-07-11T05:57:34.172321+00:00"},"creditUsagePercent":36.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":36.0}],"isUnifiedBillingUser":true,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-07-04T05:57:34.172321+00:00","billingPeriodEnd":"2026-07-11T05:57:34.172321+00:00"}}
        """

    private let directory: TemporaryDirectory
    private let token = JWTFixture.token(["sub": "user-1"])
    private let owner = AccountOwner.identity(Digest.sha256(parts: ["grok", "user-1"]))

    init() throws {
        directory = try TemporaryDirectory()
    }

    private func signIn(_ key: String? = nil, expiresAt: String = "2099-01-01T00:00:00Z") throws {
        try directory.write(
            #"{"https://auth.x.ai::client":{"key":"\#(key ?? token)","expires_at":"\#(expiresAt)"}}"#,
            to: ".grok/auth.json")
    }

    private func provider(_ http: FakeHTTPClient) -> GrokProvider {
        GrokProvider(http: http, environment: [:], home: directory.url, now: { .reference() })
    }

    private func previous(owner: AccountOwner? = nil) -> ProviderUsage {
        let window = QuotaWindow(
            id: "credits", title: "Weekly", kind: .billing, usedPercent: 20,
            resetsAt: .reference(.days(3)))
        let account = AccountUsage(
            id: .default, name: "Grok", windows: [window], observedAt: .reference(-.minutes(10)),
            owner: owner ?? self.owner)
        return ProviderUsage(provider: .grok, accounts: [account])
    }

    private func account(_ usage: ProviderUsage) throws -> AccountUsage {
        #expect(usage.provider == .grok)
        #expect(usage.accounts.count == 1)
        return try #require(usage.account(.default))
    }

    @Test func sendsTheBearerAndMapsTheLiveFixture() async throws {
        defer { directory.remove() }
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

    @Test func anAbsentPercentWithAPeriodMeansZeroUsed() throws {
        let report = try GrokBillingReport(
            body: Data(
                #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"},"onDemandCap":{}}}"#
                    .utf8))
        #expect(report.window.usedPercent == 0)
        #expect(report.onDemand.amount == 0)
        #expect(report.prepaid.amount == 0)
    }

    @Test func mapsMoneyInCents() throws {
        let report = try GrokBillingReport(
            body: Data(
                """
                {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","end":"2026-08-01T00:00:00+00:00"},"creditUsagePercent":12.5,"onDemandCap":{"val":1000},"onDemandUsed":{"val":42},"prepaidBalance":{"val":250}}}
                """.utf8))
        #expect(report.window.title == "Monthly")
        #expect(report.window.usedPercent == 12.5)
        #expect(report.onDemand.amount == Decimal(string: "0.42"))
        #expect(report.onDemand.limit == 10)
        #expect(report.prepaid.amount == Decimal(string: "2.5"))
    }

    @Test func readsNumbersSentAsStrings() throws {
        let report = try GrokBillingReport(
            body: Data(
                """
                {"config":{"currentPeriod":{"type":"OTHER"},"creditUsagePercent":"36.5","onDemandUsed":{"val":"1234"},"onDemandCap":{"val":"5000"},"prepaidBalance":{"val":"x"}}}
                """.utf8))
        #expect(report.window.title == "Credits")
        #expect(report.window.usedPercent == 36.5)
        #expect(report.onDemand.amount == Decimal(string: "12.34"))
        #expect(report.onDemand.limit == 50)
        #expect(report.prepaid.amount == nil)
    }

    @Test(arguments: [#"{"config":{}}"#, "{}", "<html>", #"{"config":[]}"#])
    func aBodyWithoutAPeriodIsUnexpected(body: String) async throws {
        defer { directory.remove() }
        try signIn()
        let account = try account(
            try await provider(FakeHTTPClient(json: body)).fetch(previous: previous()))
        #expect(account.isStale)
        #expect(
            account.issue?.message
                == "Grok returned an unexpected response. Claude Meter will try again soon.")
    }

    @Test(arguments: [401, 403])
    func aRejectedSignInKeepsTheReadingWhileTheOwnerIsSignedIn(status: Int) async throws {
        defer { directory.remove() }
        try signIn()
        let account = try account(
            try await provider(FakeHTTPClient(status: status, json: "")).fetch(previous: previous())
        )
        #expect(account.isStale)
        #expect(
            account.issue?.message
                == "Grok did not accept the sign-in. Open Grok Build and run `grok login`.")
        #expect(account.issue?.needsAction == true)
    }

    @Test func anExpiredTokenIsNeverSent() async throws {
        defer { directory.remove() }
        try signIn(expiresAt: "2026-10-04T11:59:00Z")
        let http = FakeHTTPClient(json: Self.liveFixture)

        let account = try account(try await provider(http).fetch(previous: previous()))

        #expect(http.requests.isEmpty)
        #expect(account.isStale)
        #expect(account.issue?.message == "Your Grok sign-in expired. Open Grok Build to renew it.")
        #expect(account.issue?.needsAction == true)
    }

    @Test func signingOutDropsTheReading() async throws {
        defer { directory.remove() }
        let provider = provider(FakeHTTPClient(json: Self.liveFixture))
        #expect(await provider.reconcile(previous()) == nil)
        let account = try account(try await provider.fetch(previous: previous()))
        #expect(!account.hasObservation)
        #expect(account.issue?.needsAction == true)
    }

    @Test func reconcileKeepsOnlyTheSignedInOwner() async throws {
        defer { directory.remove() }
        try signIn()
        let provider = provider(FakeHTTPClient(json: Self.liveFixture))
        #expect(await provider.reconcile(previous()) == previous())
        let other = previous(owner: .identity(Digest.sha256(parts: ["grok", "user-2"])))
        #expect(await provider.reconcile(other) == nil)
    }

    @Test func anUnreadableFileKeepsTheReading() async throws {
        defer { directory.remove() }
        try directory.write("{", to: ".grok/auth.json")
        let http = FakeHTTPClient(json: Self.liveFixture)
        let provider = provider(http)

        #expect(await provider.reconcile(previous()) == previous())
        let account = try account(try await provider.fetch(previous: previous()))

        #expect(account.isStale)
        #expect(http.requests.isEmpty)
    }

    @Test func serverErrorsKeepTheReading() async throws {
        defer { directory.remove() }
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
        defer { directory.remove() }
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
        defer { directory.remove() }
        try signIn()
        let http = FakeHTTPClient { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await provider(http).fetch(previous: previous())
        }
    }

    @Test func signInStatusSendsNoRequest() async throws {
        defer { directory.remove() }
        let http = FakeHTTPClient(json: Self.liveFixture)
        let provider = provider(http)
        #expect(await provider.signInStatus() == .signedOut)
        try signIn()
        #expect(await provider.signInStatus() == .signedIn)
        #expect(http.requests.isEmpty)
    }

    @Test func diagnosticsNeverShowTheToken() async throws {
        defer { directory.remove() }
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

    @Test func homeDirectoryUsesGrokHomeOnlyWhenItIsSet() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let standard = home.appending(path: ".grok", directoryHint: .isDirectory)
        #expect(GrokProvider.homeDirectory(environment: [:], home: home) == standard)
        #expect(GrokProvider.homeDirectory(environment: ["GROK_HOME": ""], home: home) == standard)
        #expect(GrokProvider.homeDirectory(environment: ["GROK_HOME": " "], home: home) == standard)
        #expect(
            GrokProvider.homeDirectory(environment: ["GROK_HOME": "~/custom"], home: home).path
                == "/Users/someone/custom")
        #expect(
            GrokProvider.homeDirectory(environment: ["GROK_HOME": "/opt/grok"], home: home).path
                == "/opt/grok")
    }

    @Test func everyMessageTellsTheUserWhatToDo() {
        let failures: [GrokFailure] = [
            .signedOut, .sessionExpired, .sessionRejected, .rateLimited(retryAt: nil),
            .httpStatus(500), .unexpectedResponse, .offline, .timedOut, .network,
            .credentialsUnreadable, .credentialsBusy, .signInChanged,
        ]
        let instructions = [
            "run `grok", "Open Grok Build", "Claude Meter will", "Check", "Refresh",
        ]
        for failure in failures {
            let message = failure.issue.message
            #expect(instructions.contains { message.contains($0) }, "\(message)")
        }
    }
}

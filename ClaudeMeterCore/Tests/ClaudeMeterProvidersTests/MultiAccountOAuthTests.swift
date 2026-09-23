import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("MultiAccountOAuth")
struct MultiAccountOAuthTests {
    @Test func hashedServiceSuffixMatchesSHA256Prefix() {
        // sha256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        #expect(MultiAccountOAuth.hashedServiceSuffix(forPath: "abc") == "ba7816bf")
        // Empirically verified live mapping (see docs/superpowers/plans/2026-07-13):
        #expect(
            MultiAccountOAuth.hashedServiceSuffix(forPath: "/Users/jewei/.claude-oneone-tech")
                == "48c8f98c")
    }

    @Test func credentialServiceCandidates() {
        let custom = OAuthKeychain.credentialServices(
            forConfigDirPath: "/Users/jewei/.claude-oneone-tech", isDefault: false)
        #expect(custom == ["Claude Code-credentials-48c8f98c"])

        let def = OAuthKeychain.credentialServices(
            forConfigDirPath: "/Users/jewei/.claude", isDefault: true)
        // Default dir: legacy unsuffixed first, hashed as fallback.
        #expect(def.first == "Claude Code-credentials")
        #expect(def.count == 2)
        #expect(def[1].hasPrefix("Claude Code-credentials-"))
    }
}

// MARK: - fetchAll

private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _responses: [(Data, HTTPURLResponse)]
    private var _requests: [URLRequest] = []

    init(responses: [(Data, HTTPURLResponse)]) {
        _responses = responses
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        guard let response = record(request) else { throw URLError(.notConnectedToInternet) }
        return response
    }

    private func record(_ request: URLRequest) -> (Data, HTTPURLResponse)? {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
        guard !_responses.isEmpty else { return nil }
        return _responses.removeFirst()
    }
}

private actor BlockingSecondTransport: HTTPTransport {
    private let onRequest: @Sendable (Int) -> Void
    private var calls = 0
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.onRequest = onRequest
    }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        calls += 1
        onRequest(calls)
        if calls == 2 && !released {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (MultiAccountOAuthTests.usageBody(session: 30, week: 40), http)
    }

    func releaseBlockedRequest() {
        released = true
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    var requestCount: Int { calls }
}

private final class TestUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100

    func now() -> TimeInterval { lock.withLock { value } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

extension MultiAccountOAuthTests {
    fileprivate static func usageBody(session: Double, week: Double) -> Data {
        Data(
            """
            {"five_hour":{"utilization":\(session),"resets_at":"2099-01-01T00:00:00Z"},
             "seven_day":{"utilization":\(week),"resets_at":"2099-01-02T00:00:00Z"},
             "seven_day_opus":{"utilization":10,"resets_at":"2099-01-02T00:00:00Z"}}
            """.utf8)
    }

    private static func httpResponse(status: Int, orgId: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: status, httpVersion: nil,
            headerFields: orgId.map { ["anthropic-organization-id": $0] })!
    }

    private static func creds(token: String) -> OAuthCredentials {
        OAuthCredentials(
            accessToken: token, refreshToken: "r",
            expiresAt: Date(timeIntervalSinceNow: 3600), subscriptionType: "max")
    }

    @Test func fetchAllReadsEachAccountWithItsOwnToken() async {
        let transport = StubTransport(responses: [
            (Self.usageBody(session: 30, week: 40), Self.httpResponse(status: 200, orgId: "org-A")),
            (Self.usageBody(session: 70, week: 90), Self.httpResponse(status: 200, orgId: "org-B")),
        ])
        let accounts = [
            AccountConfig(
                id: "claude", label: "default",
                configDir: URL(fileURLWithPath: "/tmp/none/.claude")),
            AccountConfig(
                id: "claude-work", label: "work",
                configDir: URL(fileURLWithPath: "/tmp/none/.claude-work")),
        ]
        let loader: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials> = {
            path, _ in
            .found(Self.creds(token: path.hasSuffix(".claude-work") ? "tok-work" : "tok-default"))
        }
        let readings = await MultiAccountOAuth.fetchAll(
            accounts: accounts, home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: transport,
            credentialsLoader: loader, now: Date())

        #expect(readings.count == 2)
        #expect(transport.requests.count == 2)
        #expect(
            transport.requests[0].value(forHTTPHeaderField: "Authorization")
                == "Bearer tok-default")
        #expect(
            transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok-work")
        #expect(readings[0].organizationId == "org-A")
        #expect(readings[1].organizationId == "org-B")
        #expect(readings[1].limits.currentSession.percentUsed == 70)
        #expect(readings[1].limits.currentWeekOpus?.percentUsed == 10)
        #expect(readings[1].severity == .warning)  // 90% week >= warning 80
        #expect(readings[0].plan == "Max")
    }

    @Test func fetchAllSkipsAccountsWithoutCredentials() async {
        let transport = StubTransport(responses: [
            (Self.usageBody(session: 5, week: 5), Self.httpResponse(status: 200, orgId: nil))
        ])
        let accounts = [
            AccountConfig(
                id: "claude", label: "default",
                configDir: URL(fileURLWithPath: "/tmp/none/.claude")),
            AccountConfig(
                id: "claude-x", label: "x",
                configDir: URL(fileURLWithPath: "/tmp/none/.claude-x")),
        ]
        let loader: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials> = {
            path, _ in
            path.hasSuffix(".claude") ? .found(Self.creds(token: "t")) : .missing
        }
        let readings = await MultiAccountOAuth.fetchAll(
            accounts: accounts, home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: transport,
            credentialsLoader: loader, now: Date())
        #expect(readings.count == 1)
        #expect(readings[0].accountKey == "claude")
        #expect(transport.requests.count == 1)
    }

    @Test func detailedFetchRetainsCredentialFailureReason() async {
        let account = AccountConfig(
            id: "claude-work", label: "work",
            configDir: URL(fileURLWithPath: "/tmp/none/.claude-work"))
        let results = await MultiAccountOAuth.fetchAllResults(
            accounts: [account], home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: StubTransport(responses: []),
            credentialsLoader: { _, _ in .temporarilyUnavailable }, now: Date())
        #expect(results.count == 1)
        #expect(results.first?.reading == nil)
        #expect(results.first?.failure == .credentialsUnavailable)
    }

    @Test func fetchAllStopsOn429AndRecordsBackoff() async {
        let transport = StubTransport(responses: [
            (Data("{}".utf8), Self.httpResponse(status: 429, orgId: nil))
        ])
        let accounts = [
            AccountConfig(
                id: "claude", label: "default",
                configDir: URL(fileURLWithPath: "/tmp/none/.claude")),
            AccountConfig(
                id: "claude-y", label: "y",
                configDir: URL(fileURLWithPath: "/tmp/none/.claude-y")),
        ]
        let loader: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials> = {
            _, _ in .found(Self.creds(token: "t"))
        }
        // Far-past `now` so the backoff this records (now+60s) is long expired for
        // every other test that polls with the real clock.
        let readings = await MultiAccountOAuth.fetchAll(
            accounts: accounts, home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: transport,
            credentialsLoader: loader, now: Date(timeIntervalSince1970: 0))
        // First account 429s -> provider-wide stop; second never attempted.
        #expect(readings.isEmpty)
        #expect(transport.requests.count == 1)
    }

    @Test func perAccountTimeoutKeepsEarlierSuccessfulResult() async {
        let transport = BlockingSecondTransport()
        let accounts = Self.twoAccounts()
        let start = ProcessInfo.processInfo.systemUptime

        let results = await MultiAccountOAuth.fetchAllResults(
            accounts: accounts, home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: transport,
            credentialsLoader: { _, _ in .found(Self.creds(token: "token")) },
            now: Date(), totalTimeout: 30, perAccountTimeout: 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        await transport.releaseBlockedRequest()

        // Allow worker scheduling delay while still distinguishing the 1 s
        // account timeout from the 30 s total budget.
        #expect(elapsed < 5)
        #expect(results.count == 2)
        #expect(results.first?.accountKey == "claude")
        #expect(results.first?.reading?.limits.currentSession.percentUsed == 30)
        #expect(results.last?.accountKey == "claude-work")
        #expect(results.last?.failure == .requestFailed)
        #expect(await transport.requestCount == 2)
    }

    @Test func totalTimeoutKeepsEarlierSuccessfulResult() async {
        let uptime = TestUptime()
        let transport = BlockingSecondTransport { call in
            // Leave a short total budget only after the first request starts.
            // A slow CI worker must not exhaust it between the two accounts.
            if call == 1 { uptime.advance(by: 29.8) }
        }
        let accounts = Self.twoAccounts()
        let start = ProcessInfo.processInfo.systemUptime

        let results = await MultiAccountOAuth.fetchAllResults(
            accounts: accounts, home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: transport,
            credentialsLoader: { _, _ in .found(Self.creds(token: "token")) },
            now: Date(), totalTimeout: 30, perAccountTimeout: 10,
            uptime: { uptime.now() })
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        await transport.releaseBlockedRequest()

        // Distinguish the remaining 0.2 s total budget from the 10 s account
        // timeout without requiring CI to schedule the assertion within 1 s.
        #expect(elapsed < 5)
        #expect(results.count == 2)
        #expect(results.first?.accountKey == "claude")
        #expect(results.first?.reading?.limits.currentSession.percentUsed == 30)
        #expect(results.last?.accountKey == "claude-work")
        #expect(results.last?.failure == .requestFailed)
        #expect(await transport.requestCount == 2)
    }

    @Test(arguments: [30.0, 30.25])
    func totalTimeoutBetweenAccountsKeepsOnlyTheCompletedResult(elapsed: TimeInterval) async {
        let uptime = TestUptime()
        let transport = BlockingSecondTransport { call in
            if call == 1 { uptime.advance(by: elapsed) }
        }

        let results = await MultiAccountOAuth.fetchAllResults(
            accounts: Self.twoAccounts(), home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: transport,
            credentialsLoader: { _, _ in .found(Self.creds(token: "token")) },
            now: Date(), totalTimeout: 30, perAccountTimeout: 10,
            uptime: { uptime.now() })
        await transport.releaseBlockedRequest()

        #expect(results.count == 1)
        #expect(results.first?.accountKey == "claude")
        #expect(results.first?.reading?.limits.currentSession.percentUsed == 30)
        #expect(results.first?.failure == nil)
        #expect(await transport.requestCount == 1)
    }

    private static func twoAccounts() -> [AccountConfig] {
        [
            AccountConfig(
                id: "claude", label: "default",
                configDir: URL(fileURLWithPath: "/tmp/none/.claude")),
            AccountConfig(
                id: "claude-work", label: "work",
                configDir: URL(fileURLWithPath: "/tmp/none/.claude-work")),
        ]
    }
}

// MARK: - merge + duplicate detection

extension MultiAccountOAuthTests {
    private static func reading(
        key: String, label: String? = nil, email: String? = "user@x.com",
        org: String?, session: Double = 10, week: Double = 20, opus: Double? = 5
    ) -> OAuthAccountReading {
        OAuthAccountReading(
            accountKey: key, label: label ?? key, email: email, plan: "Max 5x",
            organizationId: org,
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: session, resetsAt: nil),
                currentWeekAllModels: LimitWindow(percentUsed: week, resetsAt: nil),
                currentWeekOpus: opus.map { LimitWindow(percentUsed: $0, resetsAt: nil) },
                extraUsage: nil),
            severity: .normal)
    }

}

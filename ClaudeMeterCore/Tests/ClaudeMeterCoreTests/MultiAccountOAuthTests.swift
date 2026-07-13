import Foundation
import Testing

@testable import ClaudeMeterCore

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

extension MultiAccountOAuthTests {
    private static func usageBody(session: Double, week: Double) -> Data {
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

    private static func statuslineSnapshot(accounts: [AccountUsage]?) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            parserVersion: "statusline-1.0", createdAt: Date(),
            source: SourceInfo(cliPath: "statusline", command: "bridge"),
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 50, resetsAt: nil),
                currentWeekAllModels: LimitWindow(percentUsed: 60, resetsAt: nil)),
            state: SnapshotState(status: .ok, severity: .normal),
            accounts: accounts)
    }

    @Test func mergeFillsExistingAccountGaps() {
        let existing = AccountUsage(
            id: "claude-work", label: "work",
            account: nil,
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 42, resetsAt: nil),
                currentWeekAllModels: LimitWindow()),
            severity: .normal, isActive: false)
        let snap = Self.statuslineSnapshot(accounts: [existing])
        let merged = MultiAccountOAuth.merge(
            readings: [Self.reading(key: "claude-work", email: "w@x.com", org: "org-W", week: 88)],
            into: snap, now: Date())
        let acc = merged.accounts!.first { $0.id == "claude-work" }!
        // Statusline session (real data) wins; empty weekly filled from OAuth.
        #expect(acc.limits.currentSession.percentUsed == 42)
        #expect(acc.limits.currentWeekAllModels.percentUsed == 88)
        #expect(acc.limits.currentWeekOpus?.percentUsed == 5)
        #expect(acc.account?.email == "w@x.com")
        #expect(acc.account?.organization == "org-W")
        #expect(acc.account?.plan == "Max 5x")
    }

    @Test func mergeAppendsUnknownAccounts() {
        let snap = Self.statuslineSnapshot(accounts: [
            AccountUsage(
                id: "claude", label: "default", limits: LimitInfo(),
                severity: .normal, isActive: true)
        ])
        let merged = MultiAccountOAuth.merge(
            readings: [Self.reading(key: "claude-idle", org: "org-I")],
            into: snap, now: Date())
        let appended = merged.accounts!.first { $0.id == "claude-idle" }
        #expect(appended != nil)
        #expect(appended?.isActive == false)
        #expect(appended?.limits.currentSession.percentUsed == 10)
        // Active account stays first.
        #expect(merged.accounts?.first?.id == "claude")
    }

    @Test func mergeLeavesSingleAccountSnapshotUntouched() {
        let snap = Self.statuslineSnapshot(accounts: nil)
        let merged = MultiAccountOAuth.merge(
            readings: [Self.reading(key: "claude", org: "org-A")], into: snap, now: Date())
        #expect(merged.accounts == nil)  // byte-compat promise
        #expect(merged.limits == snap.limits)  // top level untouched
    }

    @Test func mergeBuildsAccountsListFromTwoReadings() {
        let snap = Self.statuslineSnapshot(accounts: nil)
        let merged = MultiAccountOAuth.merge(
            readings: [
                Self.reading(key: "claude-work", org: "org-W"),
                Self.reading(key: "claude", org: "org-A"),
            ],
            into: snap, now: Date())
        #expect(merged.accounts?.count == 2)
        #expect(merged.accounts?.first?.id == "claude")
        #expect(merged.accounts?.first?.isActive == true)
        #expect(merged.limits == snap.limits)
    }

    @Test func duplicateOrgDetection() {
        let a = AccountUsage(
            id: "claude", label: "default",
            account: AccountInfo(organization: "org-same"),
            limits: LimitInfo(), severity: .normal, isActive: true)
        let b = AccountUsage(
            id: "claude-copy", label: "copy",
            account: AccountInfo(organization: "org-same"),
            limits: LimitInfo(), severity: .normal, isActive: false)
        let c = AccountUsage(
            id: "claude-other", label: "other",
            account: AccountInfo(organization: "org-diff"),
            limits: LimitInfo(), severity: .normal, isActive: false)
        #expect(
            MultiAccountOAuth.duplicateOrgAccountKeys([a, b, c]) == ["claude", "claude-copy"])
        #expect(MultiAccountOAuth.duplicateOrgAccountKeys([a, c]).isEmpty)
    }
}

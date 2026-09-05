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

    @Test func newerTopLevelOAuthDetailsClearOlderActiveAccountDetails() throws {
        let olderAt = Date(timeIntervalSince1970: 100)
        let topLevelAt = Date(timeIntervalSince1970: 200)
        let oldScope = ScopedLimitWindow(
            id: "seven_day_sonnet",
            window: LimitWindow(percentUsed: 44))
        let oldExtra = ExtraUsage(isEnabled: true, usedCredits: 500)
        let oldLimits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 30),
            currentWeekAllModels: LimitWindow(percentUsed: 40),
            currentWeekOpus: LimitWindow(percentUsed: 50),
            scopedWeekly: [oldScope],
            extraUsage: oldExtra)
        let active = AccountUsage(
            id: "claude",
            label: "default",
            account: AccountInfo(email: "active@example.com", plan: "Old plan"),
            limits: oldLimits,
            severity: .normal,
            isActive: true)
        var snapshot = Self.statuslineSnapshot(accounts: [active])
        snapshot.account = AccountInfo(email: "active@example.com")
        snapshot.limits.currentWeekOpus = nil
        snapshot.limits.scopedWeekly = nil
        snapshot.limits.extraUsage = nil
        let olderReading = OAuthAccountReading(
            accountKey: "claude",
            label: "default",
            email: "active@example.com",
            plan: "Old plan",
            organizationId: "org",
            limits: oldLimits,
            severity: .normal,
            fetchedAt: olderAt)

        let merged = MultiAccountOAuth.merge(
            readings: [olderReading],
            into: snapshot,
            now: topLevelAt,
            activeTopLevelOAuthDetailsObservedAt: topLevelAt)
        let mergedActive = try #require(merged.accounts?.first)

        #expect(merged.account == AccountInfo(email: "active@example.com"))
        #expect(merged.limits.currentWeekOpus == nil)
        #expect(merged.limits.scopedWeekly == nil)
        #expect(merged.limits.extraUsage == nil)
        #expect(mergedActive.account?.email == "active@example.com")
        #expect(mergedActive.account?.organization == "org")
        #expect(mergedActive.account?.plan == nil)
        #expect(mergedActive.limits.currentWeekOpus == nil)
        #expect(mergedActive.limits.scopedWeekly == nil)
        #expect(mergedActive.limits.extraUsage == nil)
    }

    @Test func newerPerAccountOAuthDetailsClearOlderTopLevelDetails() throws {
        let topLevelAt = Date(timeIntervalSince1970: 100)
        let accountAt = Date(timeIntervalSince1970: 200)
        let oldScope = ScopedLimitWindow(
            id: "seven_day_sonnet",
            window: LimitWindow(percentUsed: 44))
        let oldExtra = ExtraUsage(isEnabled: true, usedCredits: 500)
        let oldLimits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 30),
            currentWeekAllModels: LimitWindow(percentUsed: 40),
            currentWeekOpus: LimitWindow(percentUsed: 50),
            scopedWeekly: [oldScope],
            extraUsage: oldExtra)
        let active = AccountUsage(
            id: "claude",
            label: "default",
            account: AccountInfo(email: "active@example.com", plan: "Old plan"),
            limits: oldLimits,
            severity: .normal,
            isActive: true)
        var snapshot = Self.statuslineSnapshot(accounts: [active])
        snapshot.account = AccountInfo(email: "active@example.com", plan: "Old plan")
        snapshot.limits = oldLimits
        let newerEmptyReading = OAuthAccountReading(
            accountKey: "claude",
            label: "default",
            email: nil,
            plan: nil,
            organizationId: nil,
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 30),
                currentWeekAllModels: LimitWindow(percentUsed: 40)),
            severity: .normal,
            fetchedAt: accountAt)

        let merged = MultiAccountOAuth.merge(
            readings: [newerEmptyReading],
            into: snapshot,
            now: accountAt,
            activeTopLevelOAuthDetailsObservedAt: topLevelAt)
        let mergedActive = try #require(merged.accounts?.first)

        #expect(merged.account == AccountInfo(email: "active@example.com"))
        #expect(merged.limits.currentWeekOpus == nil)
        #expect(merged.limits.scopedWeekly == nil)
        #expect(merged.limits.extraUsage == nil)
        #expect(mergedActive.account?.email == "active@example.com")
        #expect(mergedActive.account?.plan == nil)
        #expect(mergedActive.limits.currentWeekOpus == nil)
        #expect(mergedActive.limits.scopedWeekly == nil)
        #expect(mergedActive.limits.extraUsage == nil)
    }

    @Test func equalObservationTimePrefersPerAccountOAuthDetails() {
        let observedAt = Date(timeIntervalSince1970: 100)
        let topScope = ScopedLimitWindow(
            id: "seven_day_sonnet",
            window: LimitWindow(percentUsed: 10))
        let accountScope = ScopedLimitWindow(
            id: "seven_day_cowork",
            window: LimitWindow(percentUsed: 80))
        let active = AccountUsage(
            id: "claude",
            label: "default",
            account: AccountInfo(plan: "Top plan"),
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 30),
                currentWeekAllModels: LimitWindow(percentUsed: 40),
                currentWeekOpus: LimitWindow(percentUsed: 20),
                scopedWeekly: [topScope],
                extraUsage: ExtraUsage(isEnabled: true, usedCredits: 100)),
            severity: .normal,
            isActive: true)
        var snapshot = Self.statuslineSnapshot(accounts: [active])
        snapshot.account = active.account
        snapshot.limits = active.limits
        let accountReading = OAuthAccountReading(
            accountKey: "claude",
            label: "default",
            email: nil,
            plan: "Account plan",
            organizationId: nil,
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 30),
                currentWeekAllModels: LimitWindow(percentUsed: 40),
                currentWeekOpus: LimitWindow(percentUsed: 70),
                scopedWeekly: [accountScope],
                extraUsage: ExtraUsage(isEnabled: true, usedCredits: 900)),
            severity: .normal,
            fetchedAt: observedAt)

        let merged = MultiAccountOAuth.merge(
            readings: [accountReading],
            into: snapshot,
            now: observedAt,
            activeTopLevelOAuthDetailsObservedAt: observedAt)

        #expect(merged.account?.plan == "Account plan")
        #expect(merged.limits.currentWeekOpus?.percentUsed == 70)
        #expect(merged.limits.scopedWeekly == [accountScope])
        #expect(merged.limits.extraUsage?.usedCredits == 900)
        #expect(merged.accounts?.first?.account?.plan == "Account plan")
        #expect(merged.accounts?.first?.limits.currentWeekOpus?.percentUsed == 70)
        #expect(merged.accounts?.first?.limits.scopedWeekly == [accountScope])
        #expect(merged.accounts?.first?.limits.extraUsage?.usedCredits == 900)
    }

    /// An accounts-nil statusline snapshot is the default account. A successful
    /// secondary OAuth request must not take ownership of its top-level fields.
    @Test func mergeSurfacesLoneNonDefaultAccount() {
        let snap = Self.statuslineSnapshot(accounts: nil)
        let merged = MultiAccountOAuth.merge(
            readings: [Self.reading(key: "claude-work", org: "org-1")], into: snap, now: Date())

        #expect(merged.accounts?.count == 2)
        #expect(merged.accounts?.first?.id == "claude")
        #expect(merged.accounts?.first?.isActive == true)
        #expect(merged.accounts?.first { $0.id == "claude-work" }?.isActive == false)
        #expect(merged.limits.currentSession.percentUsed == 50)
    }

    @Test func secondaryOAuthCannotRepairExpiredDefaultTopLevelWindow() throws {
        let resetAt = Date(timeIntervalSince1970: 10_000)
        let now = resetAt.addingTimeInterval(60)
        let expired = LimitWindow(percentUsed: 67, resetsAt: resetAt)
        var snap = Self.statuslineSnapshot(accounts: nil)
        snap.limits.currentSession = expired
        let work = OAuthAccountReading(
            accountKey: "claude-work",
            label: "work",
            email: nil,
            plan: nil,
            organizationId: nil,
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 85,
                    resetsAt: now.addingTimeInterval(5 * 3_600)),
                currentWeekAllModels: LimitWindow(percentUsed: 60)),
            severity: .warning,
            fetchedAt: now)

        let merged = MultiAccountOAuth.merge(readings: [work], into: snap, now: now)
        let defaultAccount = try #require(merged.accounts?.first { $0.id == "claude" })
        let workAccount = try #require(merged.accounts?.first { $0.id == "claude-work" })

        #expect(merged.limits.currentSession == expired)
        #expect(defaultAccount.isActive)
        #expect(defaultAccount.limits.currentSession == expired)
        #expect(!workAccount.isActive)
        #expect(workAccount.limits.currentSession == work.limits.currentSession)
    }

    /// A lone *default* account keeps `accounts == nil` so `current.json` stays
    /// byte-identical to the historical single-account shape.
    @Test func mergeLeavesLoneDefaultAccountUnlisted() {
        let snap = Self.statuslineSnapshot(accounts: nil)
        let merged = MultiAccountOAuth.merge(
            readings: [Self.reading(key: "claude", org: "org-1")], into: snap, now: Date())
        #expect(merged.accounts == nil)
    }

    /// `fetchAll` is public and maps 1:1 over a caller-supplied account list, so a
    /// duplicate key must degrade rather than trap the app mid-poll.
    @Test func mergeToleratesDuplicateAccountKeys() {
        let snap = Self.statuslineSnapshot(accounts: nil)
        let merged = MultiAccountOAuth.merge(
            readings: [
                Self.reading(key: "claude-work", org: "org-1", session: 11),
                Self.reading(key: "claude-work", org: "org-2", session: 22),
            ],
            into: snap, now: Date())
        #expect(merged.accounts?.count == 2)
        #expect(
            merged.accounts?.first { $0.id == "claude-work" }?.limits.currentSession.percentUsed
                == 11)
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

    @Test func staleSnapshotReplacesCachedActiveAccountFromNewerOAuthReading() throws {
        let cachedAt = Date(timeIntervalSince1970: 10_000)
        let fetchedAt = cachedAt.addingTimeInterval(300)
        let cachedSession = SessionInfo(id: "cached-session", activeModel: "cached-model")
        let cachedLimits = LimitInfo(
            currentSession: LimitWindow(
                percentUsed: 12,
                resetsAt: fetchedAt.addingTimeInterval(3_600)),
            currentWeekAllModels: LimitWindow(
                percentUsed: 23,
                resetsAt: fetchedAt.addingTimeInterval(6 * 86_400)),
            currentWeekOpus: LimitWindow(percentUsed: 34),
            scopedWeekly: [
                ScopedLimitWindow(
                    id: "seven_day_sonnet",
                    window: LimitWindow(percentUsed: 45))
            ],
            extraUsage: ExtraUsage(isEnabled: true, usedCredits: 100))
        let cachedActive = AccountUsage(
            id: "claude-work",
            label: "saved label",
            account: AccountInfo(
                loginMethod: "OAuth",
                organization: "old-org",
                email: "old@example.com",
                plan: "Pro"),
            session: cachedSession,
            limits: cachedLimits,
            lastSuccessfulPollAt: cachedAt,
            severity: .normal,
            isActive: true)
        let cachedInactive = AccountUsage(
            id: "claude-other",
            label: "other",
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 9),
                currentWeekAllModels: LimitWindow(percentUsed: 19)),
            lastSuccessfulPollAt: cachedAt,
            severity: .normal,
            isActive: false)
        let freshLimits = LimitInfo(
            currentSession: LimitWindow(
                percentUsed: 87,
                resetsAt: fetchedAt.addingTimeInterval(5 * 3_600)),
            currentWeekAllModels: LimitWindow(
                percentUsed: 91,
                resetsAt: fetchedAt.addingTimeInterval(7 * 86_400)),
            currentWeekOpus: LimitWindow(percentUsed: 96),
            scopedWeekly: [
                ScopedLimitWindow(
                    id: "seven_day_cowork",
                    window: LimitWindow(percentUsed: 66))
            ],
            extraUsage: ExtraUsage(
                isEnabled: true,
                usedCredits: 250,
                monthlyLimit: 1_000,
                decimalPlaces: 2,
                utilization: 25,
                currency: "USD"))
        let freshReading = OAuthAccountReading(
            accountKey: "claude-work",
            label: "new label",
            email: "new@example.com",
            plan: "Max 5x",
            organizationId: "new-org",
            limits: freshLimits,
            severity: .critical,
            fetchedAt: fetchedAt)
        var snapshot = Self.statuslineSnapshot(accounts: [cachedActive, cachedInactive])
        snapshot.account = cachedActive.account
        snapshot.session = cachedSession
        snapshot.limits = cachedLimits
        snapshot.lastSuccessfulPollAt = cachedAt
        snapshot.state = SnapshotState(status: .stale, isStale: true, severity: .normal)

        let merged = MultiAccountOAuth.merge(
            readings: [freshReading],
            into: snapshot,
            now: fetchedAt,
            thresholds: .default)
        let active = try #require(merged.accounts?.first { $0.id == "claude-work" })
        let inactive = try #require(merged.accounts?.first { $0.id == "claude-other" })

        #expect(active.id == cachedActive.id)
        #expect(active.label == cachedActive.label)
        #expect(active.session == cachedSession)
        #expect(active.isActive)
        #expect(
            active.account
                == AccountInfo(
                    loginMethod: "OAuth",
                    organization: "new-org",
                    email: "new@example.com",
                    plan: "Max 5x"))
        #expect(active.limits == freshLimits)
        #expect(active.lastSuccessfulPollAt == fetchedAt)
        #expect(active.severity == .critical)
        #expect(inactive == cachedInactive)

        #expect(merged.account == active.account)
        #expect(merged.session == cachedSession)
        #expect(merged.limits == freshLimits)
        #expect(merged.lastSuccessfulPollAt == fetchedAt)
        #expect(merged.state.severity == .critical)
        #expect(merged.state.isStale)
    }

    @Test func staleSnapshotDoesNotMirrorARefreshedInactiveAccount() throws {
        let cachedAt = Date(timeIntervalSince1970: 20_000)
        let fetchedAt = cachedAt.addingTimeInterval(300)
        let activeLimits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 31),
            currentWeekAllModels: LimitWindow(percentUsed: 41))
        let cachedActive = AccountUsage(
            id: "claude",
            label: "default",
            account: AccountInfo(email: "active@example.com", plan: "Pro"),
            limits: activeLimits,
            lastSuccessfulPollAt: cachedAt,
            severity: .normal,
            isActive: true)
        let cachedInactive = AccountUsage(
            id: "claude-work",
            label: "work",
            account: AccountInfo(email: "old-work@example.com", plan: "Pro"),
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 10),
                currentWeekAllModels: LimitWindow(percentUsed: 20)),
            lastSuccessfulPollAt: cachedAt,
            severity: .normal,
            isActive: false)
        let freshLimits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 88),
            currentWeekAllModels: LimitWindow(percentUsed: 89),
            currentWeekOpus: LimitWindow(percentUsed: 90))
        let freshReading = OAuthAccountReading(
            accountKey: "claude-work",
            label: "work",
            email: "new-work@example.com",
            plan: "Max 5x",
            organizationId: "work-org",
            limits: freshLimits,
            severity: .warning,
            fetchedAt: fetchedAt)
        var snapshot = Self.statuslineSnapshot(accounts: [cachedActive, cachedInactive])
        snapshot.account = cachedActive.account
        snapshot.limits = activeLimits
        snapshot.lastSuccessfulPollAt = cachedAt
        snapshot.state = SnapshotState(status: .stale, isStale: true, severity: .normal)

        let merged = MultiAccountOAuth.merge(
            readings: [freshReading], into: snapshot, now: fetchedAt)
        let active = try #require(merged.accounts?.first { $0.id == "claude" })
        let inactive = try #require(merged.accounts?.first { $0.id == "claude-work" })

        #expect(active == cachedActive)
        #expect(inactive.limits == freshLimits)
        #expect(inactive.lastSuccessfulPollAt == fetchedAt)
        #expect(!inactive.isActive)
        #expect(merged.account == cachedActive.account)
        #expect(merged.limits == activeLimits)
        #expect(merged.lastSuccessfulPollAt == cachedAt)
        #expect(merged.state.severity == .normal)
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

    @Test func mergeKeepsSingleAccountShapeAndStatuslineWindows() {
        let snap = Self.statuslineSnapshot(accounts: nil)
        let reading = Self.reading(key: "claude", org: "org-A")
        let merged = MultiAccountOAuth.merge(
            readings: [reading], into: snap, now: Date())
        #expect(merged.accounts == nil)  // byte-compat promise
        #expect(merged.limits.currentSession == snap.limits.currentSession)
        #expect(merged.limits.currentWeekAllModels == snap.limits.currentWeekAllModels)
        #expect(merged.limits.currentWeekOpus == reading.limits.currentWeekOpus)
    }

    @Test func postResetOAuthRepairsExpiredStatuslineWindows() throws {
        let resetAt = Date(timeIntervalSince1970: 10_000)
        let now = resetAt.addingTimeInterval(60)
        let nextReset = now.addingTimeInterval(5 * 3_600)
        let expired = LimitWindow(percentUsed: 67, resetsAt: resetAt)
        var snap = Self.statuslineSnapshot(accounts: nil)
        snap.lastSuccessfulPollAt = now.addingTimeInterval(-1)
        snap.limits.currentSession = expired
        snap.accounts = [
            AccountUsage(
                id: "claude",
                label: "default",
                limits: LimitInfo(
                    currentSession: expired,
                    currentWeekAllModels: snap.limits.currentWeekAllModels),
                lastSuccessfulPollAt: now.addingTimeInterval(-1),
                severity: .normal,
                isActive: true)
        ]
        let reading = OAuthAccountReading(
            accountKey: "claude",
            label: "default",
            email: nil,
            plan: nil,
            organizationId: nil,
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 85, resetsAt: nextReset),
                currentWeekAllModels: LimitWindow(percentUsed: 60)),
            severity: .warning,
            fetchedAt: now)

        let merged = MultiAccountOAuth.merge(readings: [reading], into: snap, now: now)
        let account = try #require(merged.accounts?.first)

        #expect(merged.limits.currentSession == reading.limits.currentSession)
        #expect(merged.lastSuccessfulPollAt == now)
        #expect(merged.state.severity == .warning)
        #expect(account.limits.currentSession == reading.limits.currentSession)
        #expect(account.lastSuccessfulPollAt == now)
        #expect(account.severity == .warning)
    }

    @Test func preResetOAuthDoesNotReplaceExpiredStatuslineWindows() throws {
        let resetAt = Date(timeIntervalSince1970: 10_000)
        let now = resetAt.addingTimeInterval(60)
        let expired = LimitWindow(percentUsed: 67, resetsAt: resetAt)
        var snap = Self.statuslineSnapshot(accounts: nil)
        snap.limits.currentSession = expired
        snap.accounts = [
            AccountUsage(
                id: "claude",
                label: "default",
                limits: LimitInfo(
                    currentSession: expired,
                    currentWeekAllModels: snap.limits.currentWeekAllModels),
                severity: .normal,
                isActive: true)
        ]
        let reading = OAuthAccountReading(
            accountKey: "claude",
            label: "default",
            email: nil,
            plan: nil,
            organizationId: nil,
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 85,
                    resetsAt: now.addingTimeInterval(5 * 3_600)),
                currentWeekAllModels: LimitWindow(percentUsed: 60)),
            severity: .warning,
            fetchedAt: resetAt.addingTimeInterval(-1))

        let merged = MultiAccountOAuth.merge(readings: [reading], into: snap, now: now)
        let account = try #require(merged.accounts?.first)

        #expect(merged.limits.currentSession == expired)
        #expect(account.limits.currentSession == expired)
        #expect(account.limits.currentSession.resolved(asOf: now).percentUsed == 0)
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
        #expect(merged.limits.currentSession == snap.limits.currentSession)
        #expect(merged.limits.currentWeekAllModels == snap.limits.currentWeekAllModels)
        #expect(merged.limits.currentWeekOpus?.percentUsed == 5)
    }

    @Test func mergePreservesTheReadingObservationTime() {
        let observed = Date(timeIntervalSince1970: 100)
        let mergedAt = Date(timeIntervalSince1970: 10_000)
        let base = Self.reading(key: "claude-work", org: "org-W")
        let reading = OAuthAccountReading(
            accountKey: base.accountKey, label: base.label, email: base.email, plan: base.plan,
            organizationId: base.organizationId, limits: base.limits, severity: base.severity,
            fetchedAt: observed)
        let merged = MultiAccountOAuth.merge(
            readings: [reading], into: Self.statuslineSnapshot(accounts: nil), now: mergedAt)
        #expect(
            merged.accounts?.first { $0.id == "claude-work" }?.lastSuccessfulPollAt == observed)
    }

    @Test func retainedReadingHidesAWindowAfterItsReset() throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let resetAt = observedAt.addingTimeInterval(60)
        let base = Self.reading(key: "claude-work", org: "org-W")
        let retained = OAuthAccountReading(
            accountKey: base.accountKey,
            label: base.label,
            email: base.email,
            plan: base.plan,
            organizationId: base.organizationId,
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 98, resetsAt: resetAt),
                currentWeekAllModels: LimitWindow(
                    percentUsed: 20,
                    resetsAt: resetAt.addingTimeInterval(10_000))),
            severity: .critical,
            fetchedAt: observedAt)

        let merged = MultiAccountOAuth.merge(
            readings: [retained],
            into: Self.statuslineSnapshot(accounts: nil),
            now: resetAt.addingTimeInterval(1))
        let account = try #require(merged.accounts?.first { $0.id == "claude-work" })

        #expect(account.limits.currentSession.percentUsed == nil)
        #expect(account.limits.currentSession.resetsAt == nil)
        #expect(account.limits.currentWeekAllModels.percentUsed == 20)
        #expect(account.severity == .normal)
        #expect(account.lastSuccessfulPollAt == observedAt)
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

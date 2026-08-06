import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

// Serialized: several cases mutate process-wide `OAuthSharedState` (the cached-
// credentials map), so running them in parallel races on shared global state.
@Suite("OAuthPipeline", .serialized)
struct OAuthPipelineTests {
    @Test func decodesUsageResponseWithExtraFields() throws {
        let json = """
            {"five_hour":{"utilization":81.0,"resets_at":"2026-06-23T11:30:00.462328+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day":{"utilization":61.0,"resets_at":"2026-06-27T07:00:00.462348+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day_oauth_apps":null,"limits":[],"spend":{},"extra_usage":{"is_enabled":false}}
            """
        let data = try #require(json.data(using: .utf8))
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        #expect(usage.fiveHour?.utilization == 81.0)
        #expect(usage.sevenDay?.utilization == 61.0)
    }

    @Test func verificationPercentagesUseApiPercentScale() throws {
        let json = """
            {"five_hour":{"utilization":81.0},"seven_day":{"utilization":61.0}}
            """
        let data = try #require(json.data(using: .utf8))
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        let percentages = OAuthPipeline.verificationPercentages(from: usage)
        #expect(percentages.sessionPct == 81.0)
        #expect(percentages.weekPct == 61.0)
    }

    @Test func decodesOpusWeeklyAndExtraUsage() throws {
        let json = """
            {"five_hour":{"utilization":40.0,"resets_at":"2026-06-24T15:00:00+00:00"},
             "seven_day":{"utilization":55.0,"resets_at":"2026-06-30T07:00:00+00:00"},
             "seven_day_opus":{"utilization":88.0,"resets_at":"2026-06-30T07:00:00+00:00"},
             "extra_usage":{"is_enabled":false,"used_credits":1615,"monthly_limit":2000,"utilization":80.75,"currency":"USD","decimal_places":2}}
            """
        let data = try #require(json.data(using: .utf8))
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        #expect(usage.sevenDayOpus?.utilization == 88.0)
        let extra = try #require(usage.extraUsage?.model)
        #expect(!extra.isEnabled)
        #expect(extra.usedAmount == 16.15)
        #expect(extra.limitAmount == 20.0)
        #expect(extra.percentUsed == 80.75)
        #expect(extra.hasSpend)
    }

    @Test func toleratesNullUtilizationWithoutFailingDecode() throws {
        let json = """
            {"five_hour":{"utilization":null,"resets_at":null},"seven_day":{"utilization":61.0}}
            """
        let data = try #require(json.data(using: .utf8))
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        #expect(usage.fiveHour?.utilization == nil)
        #expect(usage.sevenDay?.utilization == 61.0)
    }

    @Test func decodesScopedSevenDayWindows() throws {
        let json = """
            {"five_hour":{"utilization":20.0},
             "seven_day":{"utilization":61.0},
             "seven_day_opus":{"utilization":80.0},
             "seven_day_sonnet":{"utilization":34.0,"resets_at":"2026-07-20T00:00:00Z"},
             "seven_day_cowork":{"utilization":null},
             "seven_day_omelette":[1,2],
             "limits":[{"kind":"weekly"}]}
            """
        let data = try #require(json.data(using: .utf8))
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)

        // Opus stays a first-class field; only extra seven_day_* keys are scoped,
        // a non-quota shape is skipped, and a null-utilization scope is dropped
        // by the window mapper.
        #expect(usage.sevenDayOpus?.utilization == 80.0)
        #expect(usage.scopedWeekly.map(\.key) == ["seven_day_cowork", "seven_day_sonnet"])
        let scoped = try #require(OAuthPipeline.scopedWindows(from: usage))
        #expect(scoped.map(\.id) == ["seven_day_sonnet"])
        #expect(scoped.first?.window.percentUsed == 34.0)
        #expect(scoped.first?.displayName == "Sonnet")
    }

    @Test func retryAfterParsesDeltaSeconds() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "120"]
            ))
        let date = OAuthPipeline.retryAfterDate(from: response, now: now)
        #expect(date == now.addingTimeInterval(120))
    }

    @Test func retryAfterAbsentReturnsNil() throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: [:]
            ))
        #expect(OAuthPipeline.retryAfterDate(from: response, now: Date()) == nil)
    }

    @Test func bindingDisplayPercentUsesHighestWindow() {
        let now = Date()
        let limits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 20, resetsAt: now.addingTimeInterval(3600)),
            currentWeekAllModels: LimitWindow(
                percentUsed: 40, resetsAt: now.addingTimeInterval(86400)),
            currentWeekOpus: LimitWindow(percentUsed: 92, resetsAt: now.addingTimeInterval(86400))
        )
        #expect(limits.bindingDisplayPercent(asOf: now) == "92%")
    }

    @Test func cachedCredentialsAreScopedByOAuthMode() {
        OAuthPipeline.clearCachedCredentials()
        defer { OAuthPipeline.clearCachedCredentials() }

        let auto = OAuthCredentials(
            accessToken: "auto-access",
            refreshToken: "auto-refresh",
            expiresAt: .distantFuture
        )
        let manual = OAuthCredentials(
            accessToken: "manual-access",
            refreshToken: "manual-refresh",
            expiresAt: .distantFuture
        )

        OAuthPipeline.setCachedCredentialsForTesting(auto, oauthMode: "auto")
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "auto")?.accessToken
                == "auto-access")
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "manual") == nil)

        OAuthPipeline.setCachedCredentialsForTesting(manual, oauthMode: "manual")
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "manual")?
                .accessToken == "manual-access")
    }

    @Test func sourceCredentialsBeatCachedCredentials() {
        OAuthPipeline.clearCachedCredentials()
        defer { OAuthPipeline.clearCachedCredentials() }

        let cached = OAuthCredentials(
            accessToken: "cached-access",
            refreshToken: "cached-refresh",
            expiresAt: .distantFuture
        )
        let source = OAuthCredentials(
            accessToken: "source-access",
            refreshToken: "source-refresh",
            expiresAt: .distantFuture
        )

        OAuthPipeline.setCachedCredentialsForTesting(cached, oauthMode: "manual")
        let resolved = OAuthPipeline.credentials(from: .found(source), oauthMode: "manual")
        #expect(resolved?.accessToken == "source-access")
    }

    /// The in-memory chain must survive its own access token expiring. After an
    /// auto refresh the Keychain still holds the *consumed* refresh token; falling
    /// back to it once the cache aged out produced `invalid_grant`, which
    /// terminally gated the account until Claude Code rewrote the entry itself.
    @Test func expiredCacheStillBeatsOlderExpiredKeychain() {
        OAuthPipeline.clearCachedCredentials()
        defer { OAuthPipeline.clearCachedCredentials() }

        let now = Date()
        // Keychain: the pre-refresh credential. Its refresh token was consumed.
        let staleKeychain = OAuthCredentials(
            accessToken: "old", refreshToken: "R_consumed",
            expiresAt: now.addingTimeInterval(-7200))
        // Cache: the rotated credential, whose access token has *also* now expired
        // — but it carries the only refresh token Anthropic still honors.
        let expiredCache = OAuthCredentials(
            accessToken: "newer", refreshToken: "R_live",
            expiresAt: now.addingTimeInterval(-60))
        OAuthPipeline.setCachedCredentialsForTesting(expiredCache, oauthMode: "auto")

        #expect(
            OAuthPipeline.credentials(from: .found(staleKeychain), oauthMode: "auto")?
                .refreshToken == "R_live")
    }

    /// The converse: once Claude Code refreshes its own entry, that credential is
    /// newer than anything we cached and must win.
    @Test func newerKeychainBeatsOlderCache() {
        OAuthPipeline.clearCachedCredentials()
        defer { OAuthPipeline.clearCachedCredentials() }

        let now = Date()
        let cached = OAuthCredentials(
            accessToken: "ours", refreshToken: "R_ours",
            expiresAt: now.addingTimeInterval(600))
        let refreshedByClaudeCode = OAuthCredentials(
            accessToken: "theirs", refreshToken: "R_theirs",
            expiresAt: now.addingTimeInterval(3600))
        OAuthPipeline.setCachedCredentialsForTesting(cached, oauthMode: "auto")

        #expect(
            OAuthPipeline.credentials(from: .found(refreshedByClaudeCode), oauthMode: "auto")?
                .refreshToken == "R_theirs")
    }

    /// A skipped refresh must say *why*. A rejected token needs `claude login`;
    /// a transient backoff clears itself — the popover shows different copy and a
    /// different tone for each, so collapsing both onto `refreshDeferred` would
    /// tell a signed-out user to sit and wait.
    @Test func deferredReasonDistinguishesDeadTokenFromBackoff() {
        OAuthRefreshGate.resetForTesting()
        defer { OAuthRefreshGate.resetForTesting() }
        let now = Date()

        // Open gate → nothing is deferred.
        #expect(OAuthRefreshGate.availability(refreshToken: "R", now: now) == .allowed)

        // Transient failure → backing off, and reported as such.
        OAuthRefreshGate.recordTransient(now: now)
        #expect(OAuthRefreshGate.availability(refreshToken: "R", now: now) == .backingOff)
        #expect(OAuthRefreshGate.deferredReason(refreshToken: "R", now: now) == .refreshDeferred)

        // Terminal rejection of that exact token → reported as rejected...
        OAuthRefreshGate.recordTerminal(refreshToken: "R")
        #expect(OAuthRefreshGate.availability(refreshToken: "R", now: now) == .tokenRejected)
        #expect(OAuthRefreshGate.deferredReason(refreshToken: "R", now: now) == .refreshRejected)

        // ...but a *different* stored token reopens the gate, which is how
        // re-authenticating in Claude Code recovers with no manual reset.
        #expect(OAuthRefreshGate.availability(refreshToken: "R2", now: now) == .allowed)
    }

    @Test func rateLimitBackoffIsNeverShortened() {
        let now = Date()
        // A 429 asking for ten minutes.
        OAuthPipeline.recordRateLimit(retryAfter: now.addingTimeInterval(600), now: now)
        // A second 429 with no header would default to 60 s — it must not win.
        OAuthPipeline.recordRateLimit(retryAfter: nil, now: now)
        #expect(OAuthPipeline.isRateLimited(now: now.addingTimeInterval(120)))

        // A genuinely longer window still extends the block.
        OAuthPipeline.recordRateLimit(retryAfter: now.addingTimeInterval(1800), now: now)
        #expect(OAuthPipeline.isRateLimited(now: now.addingTimeInterval(900)))

        // And an elapsed block clears.
        #expect(!OAuthPipeline.isRateLimited(now: now.addingTimeInterval(3600)))
    }

    @Test func retryAfterParsesHTTPDate() throws {
        let now = Date(timeIntervalSince1970: 784_111_777)  // 1994-11-06T08:49:37Z
        let url = try #require(URL(string: "https://api.anthropic.com"))
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "Sun, 06 Nov 1994 08:51:37 GMT"]))
        let date = try #require(OAuthPipeline.retryAfterDate(from: response, now: now))
        #expect(abs(date.timeIntervalSince(now) - 120) < 1)
    }

    /// A `Retry-After: 0` on a 429 must not be read as "retry immediately". Left
    /// unguarded it produced `blockedUntil == now`, which `isRateLimited` clears on
    /// sight — silently disabling the process-wide gate for `poll`, `fetchEnrichment`
    /// and `MultiAccountOAuth` alike. `nil` here means `recordRateLimit` applies its
    /// 60 s default instead.
    @Test func zeroRetryAfterFallsBackToDefaultBackoff() throws {
        let now = Date()
        let url = try #require(URL(string: "https://api.anthropic.com"))
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "0"]))
        #expect(OAuthPipeline.retryAfterDate(from: response, now: now) == nil)

        OAuthPipeline.recordRateLimit(
            retryAfter: OAuthPipeline.retryAfterDate(from: response, now: now), now: now)
        // The gate is armed for the 60 s default, not open.
        #expect(OAuthPipeline.isRateLimited(now: now.addingTimeInterval(30)))
        #expect(!OAuthPipeline.isRateLimited(now: now.addingTimeInterval(61)))
    }

    @Test func retryAfterIgnoresPastHTTPDate() throws {
        let now = Date(timeIntervalSince1970: 784_111_777)
        let url = try #require(URL(string: "https://api.anthropic.com"))
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "Sun, 06 Nov 1994 08:47:37 GMT"]))
        #expect(OAuthPipeline.retryAfterDate(from: response, now: now) == nil)
    }

    @Test func freshCacheBeatsExpiredKeychain() {
        OAuthPipeline.clearCachedCredentials()
        defer { OAuthPipeline.clearCachedCredentials() }

        let expiredKeychain = OAuthCredentials(
            accessToken: "old", refreshToken: "R_A", expiresAt: .distantPast)
        let freshCache = OAuthCredentials(
            accessToken: "new", refreshToken: "R_B", expiresAt: .distantFuture)
        OAuthPipeline.setCachedCredentialsForTesting(freshCache, oauthMode: "auto")

        // Expired Keychain + fresh cache → use the cache (carries the live token).
        #expect(
            OAuthPipeline.credentials(from: .found(expiredKeychain), oauthMode: "auto")?
                .refreshToken == "R_B")

        // A non-expired Keychain entry (Claude Code refreshed it) still wins.
        let freshKeychain = OAuthCredentials(
            accessToken: "cc", refreshToken: "R_C", expiresAt: .distantFuture)
        #expect(
            OAuthPipeline.credentials(from: .found(freshKeychain), oauthMode: "auto")?
                .refreshToken == "R_C")
    }
}

/// Fails every request with a canned status and body — enough to drive the token
/// refresh to either of its two failure classifications without a network.
private struct FailingTransport: HTTPTransport {
    let status: Int
    let body: String

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), http)
    }
}

/// Both nested suites mutate `OAuthRefreshGate`'s process-wide static state.
///
/// `.serialized` on a *suite* only orders that suite's own cases — sibling suites
/// still run concurrently — so two separate serialized suites touching the gate
/// race: one calling `resetForTesting()` mid-flight clears a backoff the other is
/// asserting on. Applying the trait to a *parent* is what makes it recursive, so
/// the children also run one at a time.
@Suite("OAuth refresh gate state", .serialized)
struct OAuthRefreshGateStateTests {

    @Suite("OAuthRefreshGate")
    struct GateTests {
        private let now = Date(timeIntervalSince1970: 1_782_269_456)

        @Test("invalid_grant body is terminal, other failures are not") func classify() throws {
            let dead = try #require(#"{"error":"invalid_grant"}"#.data(using: .utf8))
            #expect(OAuthPipeline.isInvalidGrant(data: dead, status: 400))
            #expect(OAuthPipeline.isInvalidGrant(data: dead, status: 401))
            // Only auth-class statuses count.
            #expect(!OAuthPipeline.isInvalidGrant(data: dead, status: 500))
            let other = try #require(#"{"error":"server_error"}"#.data(using: .utf8))
            #expect(!OAuthPipeline.isInvalidGrant(data: other, status: 400))
            #expect(!OAuthPipeline.isInvalidGrant(data: Data(), status: 400))
        }

        @Test("Terminal blocks the dead token but reopens for a new one") func terminal() {
            OAuthRefreshGate.resetForTesting()
            defer { OAuthRefreshGate.resetForTesting() }
            #expect(OAuthRefreshGate.shouldAttempt(refreshToken: "dead", now: now))
            OAuthRefreshGate.recordTerminal(refreshToken: "dead")
            #expect(!OAuthRefreshGate.shouldAttempt(refreshToken: "dead", now: now))
            // Re-auth yields a different refresh token → gate reopens automatically.
            #expect(OAuthRefreshGate.shouldAttempt(refreshToken: "fresh", now: now))
        }

        @Test("Transient backs off then expires; success clears it") func transient() {
            OAuthRefreshGate.resetForTesting()
            defer { OAuthRefreshGate.resetForTesting() }
            OAuthRefreshGate.recordTransient(now: now)
            #expect(!OAuthRefreshGate.shouldAttempt(refreshToken: "t", now: now))
            // Still blocked within the base backoff, allowed after it elapses.
            let withinBackoff = now.addingTimeInterval(OAuthRefreshGate.baseTransientBackoff - 1)
            #expect(!OAuthRefreshGate.shouldAttempt(refreshToken: "t", now: withinBackoff))
            let afterBackoff = now.addingTimeInterval(OAuthRefreshGate.baseTransientBackoff + 1)
            #expect(OAuthRefreshGate.shouldAttempt(refreshToken: "t", now: afterBackoff))
            OAuthRefreshGate.recordTransient(now: now)
            OAuthRefreshGate.recordSuccess()
            #expect(OAuthRefreshGate.shouldAttempt(refreshToken: "t", now: now))
        }
    }

    /// `fetchEnrichment` must clear the in-memory credential on *every* refresh
    /// failure, exactly as `poll` does.
    ///
    /// Why it matters: `credentials(from:)` deliberately prefers whichever
    /// credential carries the later `expiresAt`, and `OAuthRefreshGate` reopens by
    /// *token identity*. A dead credential left resident therefore outranks the
    /// fresh entry Claude Code writes on `claude login`, and the gate stays shut
    /// against the good token until the app is relaunched.
    @Suite("OAuth enrichment credential cache")
    struct EnrichmentCacheTests {
        /// Drives `fetchEnrichment` with an expired cached credential and a
        /// transport that fails the refresh, then reports whether that credential
        /// is still resident afterwards.
        private func residentCredentialAfterFailedRefresh(
            status: Int, body: String
        ) async -> OAuthCredentials? {
            let defaults = UserDefaults.standard
            let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
            defaults.set("auto", forKey: AppGroupConfig.oauthModeKey)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthPipeline.setTransportForTesting(FailingTransport(status: status, body: body))
            defer {
                OAuthPipeline.setTransportForTesting(nil)
                OAuthPipeline.clearCachedCredentials()
                OAuthRefreshGate.resetForTesting()
                if let previousMode {
                    defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
                } else {
                    defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
                }
            }

            // An already-expired credential sitting in the cache. Under test the
            // Keychain read is fail-closed (`.temporarilyUnavailable`), so
            // `credentials(from:)` resolves to exactly this one — the same path a
            // locked Keychain takes in production.
            let dead = OAuthCredentials(
                accessToken: "dead-access",
                refreshToken: "dead-refresh-\(UUID().uuidString)",
                expiresAt: Date().addingTimeInterval(-3600)
            )
            OAuthPipeline.setCachedCredentialsForTesting(dead, oauthMode: "auto")

            let enrichment = await OAuthPipeline.fetchEnrichment()
            #expect(enrichment == nil)
            return OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "auto")
        }

        @Test func rejectedRefreshClearsTheCachedCredential() async {
            let resident = await residentCredentialAfterFailedRefresh(
                status: 400, body: #"{"error":"invalid_grant"}"#)
            #expect(resident == nil)
        }

        @Test func transientRefreshFailureAlsoClearsTheCachedCredential() async {
            let resident = await residentCredentialAfterFailedRefresh(
                status: 500, body: #"{"error":"server_error"}"#)
            #expect(resident == nil)
        }
    }
}

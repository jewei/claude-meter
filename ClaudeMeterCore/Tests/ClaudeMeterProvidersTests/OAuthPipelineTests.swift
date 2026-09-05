import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

// Serialized: these cases and the nested refresh-gate suites mutate process-wide
// OAuth state, including UserDefaults, cached credentials, and the test transport.
@Suite("OAuthPipeline", .serialized)
struct OAuthPipelineTests {
    @Test func rateLimitErrorExplainsThatItWillRetry() {
        #expect(
            OAuthError.rateLimited.localizedDescription
                == "Anthropic is rate-limiting usage checks — retrying automatically")
    }

    @Test func enrichmentRetainsWhyNoObservationWasAvailable() async {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
        defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
            }
        }

        let result = await OAuthPipeline.fetchEnrichmentResult()

        #expect(result == .unavailable(.notConnected))
    }

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

    @Test func verificationPercentagesClampExtremeServerValues() throws {
        let json = """
            {"five_hour":{"utilization":1e308},"seven_day":{"utilization":-1e308}}
            """
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        let percentages = OAuthPipeline.verificationPercentages(from: usage)

        #expect(percentages.sessionPct == 100)
        #expect(percentages.weekPct == 0)
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

    @Test func retryAfterCapsImplausibleDelay() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "999999999"]
            ))

        #expect(
            OAuthPipeline.retryAfterDate(from: response, now: now)
                == now.addingTimeInterval(OAuthPipeline.maximumRateLimitBackoff))
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
        OAuthPipeline.setCachedCredentialsForTesting(
            expiredCache,
            oauthMode: "auto",
            sourceRefreshToken: staleKeychain.refreshToken)

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
        OAuthPipeline.setCachedCredentialsForTesting(
            freshCache,
            oauthMode: "auto",
            sourceRefreshToken: expiredKeychain.refreshToken)

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

    @Test func rotatedCacheBeatsSourceWhenServerReturnsZeroLifetime() async throws {
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let transport = QueuedOAuthTransport([
            .init(
                status: 200,
                body:
                    #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":0}"#
            ),
            .init(
                status: 200,
                body: #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#),
            .init(
                status: 200,
                body: #"{"five_hour":{"utilization":11},"seven_day":{"utilization":21}}"#),
        ])
        OAuthPipeline.setTransportForTesting(transport)
        defer {
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
        }

        let source = OAuthCredentials(
            accessToken: "source-access",
            refreshToken: "source-refresh-\(UUID().uuidString)",
            expiresAt: Date().addingTimeInterval(30))
        _ = try await OAuthPipeline.verify(credentials: source, oauthMode: "auto")

        let selected = OAuthPipeline.credentials(from: .found(source), oauthMode: "auto")
        #expect(selected?.refreshToken == "rotated-refresh")
        _ = try await OAuthPipeline.verify(credentials: source, oauthMode: "auto")
        #expect(await transport.requestCount == 3)
        #expect(await transport.tokenRequestCount == 1)
    }

    @Test func preselectedCallerReusesAnAdoptedRotation() async throws {
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let usageBody = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#
        let transport = QueuedOAuthTransport([
            .init(
                status: 200,
                body:
                    #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}"#
            ),
            .init(status: 200, body: usageBody),
            .init(status: 200, body: usageBody),
            .init(status: 200, body: usageBody),
        ])
        let gate = OAuthRefreshPreselectionGate()
        OAuthPipeline.setTransportForTesting(transport)
        defer {
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
        }

        let source = OAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "preselected-refresh-\(UUID().uuidString)",
            expiresAt: .distantPast)
        let oldVerification = Task {
            try await OAuthPipeline.verifyAfterCredentialSelectionForTesting(
                credentials: source,
                oauthMode: "auto",
                beforeRefreshCoordinator: { await gate.pause() })
        }
        await gate.waitUntilPaused()

        // This caller adopts the rotation before the first caller reaches the
        // coordinator with its already-selected one-use token.
        let current = try await OAuthPipeline.verify(credentials: source, oauthMode: "auto")
        #expect(current.sessionPct == 10)
        #expect(await transport.tokenRequestCount == 1)

        await gate.release()
        let old = try await oldVerification.value
        #expect(old.weekPct == 20)

        // The late caller must reuse the retained result. Its success must not
        // clear the good cache, and a later verification must use that cache.
        let cached = OAuthPipeline.credentials(
            from: .temporarilyUnavailable,
            oauthMode: "auto")
        #expect(cached?.accessToken == "rotated-access")
        let next = try await OAuthPipeline.verify(credentials: source, oauthMode: "auto")
        #expect(next.sessionPct == 10)
        #expect(await transport.tokenRequestCount == 1)
        #expect(await transport.requestCount == 4)
    }

    @Test func lateAncestorHandoffCannotReplaceANewerRotation() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
        defaults.set("auto", forKey: AppGroupConfig.oauthModeKey)
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let usageBody = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#
        let transport = QueuedOAuthTransport([
            .init(
                status: 200,
                body:
                    #"{"access_token":"first-access","refresh_token":"first-refresh","expires_in":3600}"#
            ),
            .init(status: 200, body: usageBody),
            .init(
                status: 200,
                body:
                    #"{"access_token":"latest-access","refresh_token":"latest-refresh","expires_in":3600}"#
            ),
            .init(status: 200, body: usageBody),
            .init(status: 200, body: usageBody),
        ])
        let source = OAuthCredentials(
            accessToken: "expired-source-access",
            refreshToken: "ancestor-refresh-\(UUID().uuidString)",
            expiresAt: .distantPast)
        let gate = OAuthRefreshPreselectionGate()
        OAuthPipeline.setTransportForTesting(transport)
        OAuthPipeline.setAutomaticCredentialLoaderForTesting { .found(source) }
        defer {
            OAuthPipeline.setAutomaticCredentialLoaderForTesting(nil)
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
            if let previousMode {
                defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
            }
        }

        let oldVerification = Task {
            try await OAuthPipeline.verifyAfterCredentialSelectionForTesting(
                credentials: source,
                oauthMode: "auto",
                beforeRefreshCoordinator: { await gate.pause() })
        }
        await gate.waitUntilPaused()
        _ = try await OAuthPipeline.verify(credentials: source, oauthMode: "auto")

        let firstRotation = try #require(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "auto"))
        let store = SnapshotStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true))
        let pipeline = OAuthPipeline(fallback: OAuthFallbackPipeline(), store: store)
        _ = try await pipeline.poll(now: firstRotation.expiresAt.addingTimeInterval(1))
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "auto")?
                .refreshToken == "latest-refresh")

        await gate.release()
        do {
            _ = try await oldVerification.value
        } catch is CancellationError {
            // The old result can be rejected after a newer rotation takes its place.
        }
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "auto")?
                .refreshToken == "latest-refresh")
        #expect(await transport.tokenRequestCount == 2)
    }

    @Test func rejectedDescendantCannotRestoreAnAncestorHandoff() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
        defaults.set("auto", forKey: AppGroupConfig.oauthModeKey)
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let usageBody = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#
        let transport = QueuedOAuthTransport([
            .init(
                status: 200,
                body:
                    #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}"#
            ),
            .init(status: 200, body: usageBody),
            .init(status: 400, body: #"{"error":"invalid_grant"}"#),
        ])
        let source = OAuthCredentials(
            accessToken: "expired-source-access",
            refreshToken: "ancestor-refresh-\(UUID().uuidString)",
            expiresAt: .distantPast)
        OAuthPipeline.setTransportForTesting(transport)
        OAuthPipeline.setAutomaticCredentialLoaderForTesting { .found(source) }
        defer {
            OAuthPipeline.setAutomaticCredentialLoaderForTesting(nil)
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
            if let previousMode {
                defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
            }
        }

        // Establish O -> R and retain O's completed coordinator handoff.
        _ = try await OAuthPipeline.verify(credentials: source, oauthMode: "auto")
        OAuthPipeline.setCachedCredentialsForTesting(
            OAuthCredentials(
                accessToken: "expired-rotated-access",
                refreshToken: "rotated-refresh",
                expiresAt: .distantPast),
            oauthMode: "auto",
            sourceRefreshToken: source.refreshToken)

        let store = SnapshotStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true))
        let pipeline = OAuthPipeline(fallback: OAuthFallbackPipeline(), store: store)
        let rejected = try await pipeline.poll(now: Date())
        #expect(
            rejected.sourceAttempts.first
                == SourceAttempt(
                    source: .oauth,
                    outcome: .failed,
                    reason: .refreshRejected))
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "auto") == nil)

        // The source still contains consumed O. The rejection gate must block O,
        // and the new credential revision must make O's retained handoff unusable.
        let next = try await pipeline.poll(now: Date())
        #expect(
            next.sourceAttempts.first
                == SourceAttempt(
                    source: .oauth,
                    outcome: .skipped,
                    reason: .refreshRejected))
        #expect(await transport.tokenRequestCount == 2)
        #expect(await transport.requestCount == 3)
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "auto") == nil)
    }

    @Test(arguments: [400, 503])
    func failedVerificationClearsTheCurrentRotatedCache(status: Int) async throws {
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let source = OAuthCredentials(
            accessToken: "expired-source-access",
            refreshToken: "source-refresh-\(UUID().uuidString)",
            expiresAt: .distantPast)
        OAuthPipeline.setCachedCredentialsForTesting(
            OAuthCredentials(
                accessToken: "expired-rotated-access",
                refreshToken: "rotated-refresh",
                expiresAt: .distantPast),
            oauthMode: "auto",
            sourceRefreshToken: source.refreshToken)
        OAuthPipeline.setTransportForTesting(
            FailingTransport(status: status, body: #"{"error":"invalid_grant"}"#))
        defer {
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
        }

        await #expect(throws: OAuthError.self) {
            try await OAuthPipeline.verify(credentials: source, oauthMode: "auto")
        }

        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "auto") == nil)
        #expect(
            OAuthRefreshGate.availability(refreshToken: source.refreshToken, now: Date())
                == (status == 400 ? .tokenRejected : .backingOff))
    }

    @Test func refreshRejectsEmptyTokenStrings() async {
        let invalidBodies = [
            #"{"access_token":"","refresh_token":"rotated","expires_in":3600}"#,
            #"{"access_token":"access","refresh_token":"","expires_in":3600}"#,
        ]
        for body in invalidBodies {
            OAuthPipeline.clearCachedCredentials()
            OAuthRefreshCoordinator.resetForTesting()
            OAuthPipeline.setTransportForTesting(FailingTransport(status: 200, body: body))
            let credentials = OAuthCredentials(
                accessToken: "expired",
                refreshToken: "source-\(UUID().uuidString)",
                expiresAt: .distantPast)

            await #expect(throws: OAuthError.self) {
                try await OAuthPipeline.verify(credentials: credentials, oauthMode: "auto")
            }
        }
        OAuthPipeline.setTransportForTesting(nil)
        OAuthPipeline.clearCachedCredentials()
        OAuthRefreshCoordinator.resetForTesting()
    }

    @Test func verification429ArmsAndObeysTheSharedBackoff() async {
        OAuthPipeline.clearRateLimitForTesting()
        let transport = CountingFailingTransport(status: 429, body: "{}")
        OAuthPipeline.setTransportForTesting(transport)
        defer {
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearRateLimitForTesting()
        }
        let credentials = OAuthCredentials(
            accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
        do {
            _ = try await OAuthPipeline.verify(credentials: credentials)
            Issue.record("Expected verification to reject the 429")
        } catch {}
        #expect(OAuthPipeline.isRateLimited(now: Date()))

        do {
            _ = try await OAuthPipeline.verify(credentials: credentials)
            Issue.record("Expected the shared backoff to reject verification")
        } catch {}
        #expect(transport.calls == 1)
    }

    @Test func revocationDuringRefreshPreventsCredentialCommit() async {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
        defaults.set("manual", forKey: AppGroupConfig.oauthModeKey)
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let transport = SuspendedRefreshTransport()
        let persistence = ManualCredentialPersistenceRecorder()
        OAuthPipeline.setTransportForTesting(transport)
        OAuthPipeline.setManualCredentialPersistenceForTesting(
            save: { accessToken, refreshToken in
                persistence.recordSave(accessToken: accessToken, refreshToken: refreshToken)
            },
            delete: { persistence.recordDelete() })
        defer {
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.setManualCredentialPersistenceForTesting(save: nil, delete: nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
            if let previousMode {
                defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
            }
        }

        let credentials = OAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-\(UUID().uuidString)",
            expiresAt: .distantPast)
        let verification = Task {
            try await OAuthPipeline.verify(credentials: credentials, oauthMode: "manual")
        }
        await transport.waitUntilRequestStarts()

        // This models Disconnect while the token request is suspended.
        do {
            try OAuthPipeline.disconnect(oauthMode: "manual")
        } catch {
            Issue.record("Disconnect failed: \(error)")
        }
        await transport.releaseRequest()

        await #expect(throws: CancellationError.self) {
            try await verification.value
        }
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "manual") == nil)
        #expect(defaults.string(forKey: AppGroupConfig.oauthModeKey) == "")
        #expect(persistence.saveCount == 0)
        #expect(persistence.deleteCount == 1)
        #expect(await transport.requestCount == 1)
    }

    @Test func manualReplacementInvalidatesAnOlderRefresh() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
        defaults.set("manual", forKey: AppGroupConfig.oauthModeKey)
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let transport = SuspendedRefreshTransport()
        let persistence = ManualCredentialPersistenceRecorder()
        OAuthPipeline.setTransportForTesting(transport)
        OAuthPipeline.setManualCredentialPersistenceForTesting(
            save: { accessToken, refreshToken in
                persistence.recordSave(accessToken: accessToken, refreshToken: refreshToken)
            },
            delete: { persistence.recordDelete() })
        defer {
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.setManualCredentialPersistenceForTesting(save: nil, delete: nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
            if let previousMode {
                defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
            }
        }

        let oldCredentials = OAuthCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh-\(UUID().uuidString)",
            expiresAt: .distantPast)
        let oldVerification = Task {
            try await OAuthPipeline.verify(credentials: oldCredentials, oauthMode: "manual")
        }
        await transport.waitUntilRequestStarts()

        try OAuthPipeline.saveManualCredentials(
            accessToken: "replacement-access", refreshToken: "replacement-refresh")
        await transport.releaseRequest()

        await #expect(throws: CancellationError.self) {
            try await oldVerification.value
        }
        #expect(persistence.savedAccessTokens == ["replacement-access"])
        #expect(persistence.savedRefreshTokens == ["replacement-refresh"])
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "manual") == nil)
        #expect(await transport.requestCount == 1)
    }

    @Test func failedManualCandidateCleanupInvalidatesAnOlderRefresh() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
        defaults.set("manual", forKey: AppGroupConfig.oauthModeKey)
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let transport = SuspendedRefreshTransport()
        let persistence = ManualCredentialPersistenceRecorder()
        OAuthPipeline.setTransportForTesting(transport)
        OAuthPipeline.setManualCredentialPersistenceForTesting(
            save: { accessToken, refreshToken in
                persistence.recordSave(accessToken: accessToken, refreshToken: refreshToken)
            },
            delete: { persistence.recordDelete() })
        defer {
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.setManualCredentialPersistenceForTesting(save: nil, delete: nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
            if let previousMode {
                defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
            }
        }

        let credentials = OAuthCredentials(
            accessToken: "old-access",
            refreshToken: "old-candidate-\(UUID().uuidString)",
            expiresAt: .distantPast)
        let oldVerification = Task {
            try await OAuthPipeline.verify(credentials: credentials, oauthMode: "manual")
        }
        await transport.waitUntilRequestStarts()

        try OAuthPipeline.discardManualCredentials()
        await transport.releaseRequest()

        await #expect(throws: CancellationError.self) {
            try await oldVerification.value
        }
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "manual") == nil)
        #expect(defaults.string(forKey: AppGroupConfig.oauthModeKey) == "")
        #expect(persistence.saveCount == 0)
        #expect(persistence.deleteCount == 1)
        #expect(await transport.requestCount == 1)
    }

    @Test(arguments: [200, 400, 503])
    func newAutoKeychainChainInvalidatesAnOlderRefresh(status: Int) async {
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let transport = SuspendedRefreshTransport(status: status)
        OAuthPipeline.setTransportForTesting(transport)
        defer {
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
        }

        let oldCredentials = OAuthCredentials(
            accessToken: "old-access",
            refreshToken: "old-auto-refresh-\(UUID().uuidString)",
            expiresAt: .distantPast)
        let oldVerification = Task {
            try await OAuthPipeline.verify(credentials: oldCredentials, oauthMode: "auto")
        }
        await transport.waitUntilRequestStarts()

        // This models Claude Code replacing its Keychain entry while our refresh
        // still uses the old chain. Observing the new source invalidates the old
        // operation before it can cache its later-expiring result.
        let newCredentials = OAuthCredentials(
            accessToken: "new-access",
            refreshToken: "new-auto-refresh-\(UUID().uuidString)",
            expiresAt: .distantFuture)
        #expect(
            OAuthPipeline.credentials(from: .found(newCredentials), oauthMode: "auto")?
                .accessToken == "new-access")
        OAuthPipeline.setCachedCredentialsForTesting(newCredentials, oauthMode: "auto")
        await transport.releaseRequest()

        await #expect(throws: CancellationError.self) {
            try await oldVerification.value
        }
        #expect(
            OAuthPipeline.credentials(from: .temporarilyUnavailable, oauthMode: "auto")?
                .accessToken == "new-access")
        #expect(
            OAuthRefreshGate.availability(refreshToken: newCredentials.refreshToken, now: Date())
                == .allowed)
        #expect(await transport.requestCount == 1)
    }

    @Test func automaticKeychainReplacementDuringPollRejectsOldRefresh() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
        defaults.set("auto", forKey: AppGroupConfig.oauthModeKey)
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let transport = SuspendedRefreshTransport()
        let oldCredentials = OAuthCredentials(
            accessToken: "old-access",
            refreshToken: "old-poll-refresh-\(UUID().uuidString)",
            expiresAt: .distantPast)
        let credentialLoader = MutableOAuthCredentialLoader(.found(oldCredentials))
        OAuthPipeline.setTransportForTesting(transport)
        OAuthPipeline.setAutomaticCredentialLoaderForTesting { credentialLoader.load() }
        defer {
            OAuthPipeline.setAutomaticCredentialLoaderForTesting(nil)
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
            if let previousMode {
                defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
            }
        }

        let store = SnapshotStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true))
        let pipeline = OAuthPipeline(fallback: OAuthFallbackPipeline(), store: store)
        let poll = Task { try await pipeline.poll(now: Date()) }
        await transport.waitUntilRequestStarts()

        let newCredentials = OAuthCredentials(
            accessToken: "new-access",
            refreshToken: "new-poll-refresh-\(UUID().uuidString)",
            expiresAt: .distantFuture)
        credentialLoader.store(.found(newCredentials))
        await transport.releaseRequest()

        let result = try await poll.value
        #expect(result.snapshot?.parserVersion == "fallback-test")
        #expect(
            result.sourceAttempts.first
                == SourceAttempt(source: .oauth, outcome: .skipped, reason: .notConnected))
        #expect(
            OAuthPipeline.credentials(from: .found(newCredentials), oauthMode: "auto")?
                .accessToken == "new-access")
        #expect(await transport.requestCount == 1)
    }

    @Test func automaticKeychainReplacementDuringUsageRejectsOldResponse() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
        defaults.set("auto", forKey: AppGroupConfig.oauthModeKey)
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        let transport = SuspendedUsageTransport()
        let oldCredentials = OAuthCredentials(
            accessToken: "old-valid-access",
            refreshToken: "old-valid-refresh-\(UUID().uuidString)",
            expiresAt: .distantFuture)
        let credentialLoader = MutableOAuthCredentialLoader(.found(oldCredentials))
        OAuthPipeline.setTransportForTesting(transport)
        OAuthPipeline.setAutomaticCredentialLoaderForTesting { credentialLoader.load() }
        defer {
            OAuthPipeline.setAutomaticCredentialLoaderForTesting(nil)
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            if let previousMode {
                defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
            }
        }

        let store = SnapshotStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true))
        let pipeline = OAuthPipeline(fallback: OAuthFallbackPipeline(), store: store)
        let poll = Task { try await pipeline.poll(now: Date()) }
        await transport.waitUntilUsageStarts()

        let newCredentials = OAuthCredentials(
            accessToken: "new-valid-access",
            refreshToken: "new-valid-refresh-\(UUID().uuidString)",
            expiresAt: .distantFuture)
        credentialLoader.store(.found(newCredentials))
        await transport.releaseUsage()

        let result = try await poll.value
        #expect(result.snapshot?.parserVersion == "fallback-test")
        #expect(
            result.sourceAttempts.first
                == SourceAttempt(source: .oauth, outcome: .skipped, reason: .notConnected))
        #expect(await transport.authorizationHeaders == ["Bearer old-valid-access"])
        #expect(
            OAuthPipeline.credentials(from: .found(newCredentials), oauthMode: "auto")?
                .accessToken == "new-valid-access")
    }
}

private actor OAuthRefreshPreselectionGate {
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
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

private final class CountingFailingTransport: HTTPTransport, @unchecked Sendable {
    let status: Int
    let body: String
    private let lock = NSLock()
    private var _calls = 0

    var calls: Int { lock.withLock { _calls } }

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        lock.withLock { _calls += 1 }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), http)
    }
}

private actor QueuedOAuthTransport: HTTPTransport {
    struct Response: Sendable {
        let status: Int
        let body: String
    }

    private var responses: [Response]
    private var requestedURLs: [URL] = []
    private(set) var requestCount = 0

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        requestCount += 1
        if let url = request.url { requestedURLs.append(url) }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        return (Data(next.body.utf8), response)
    }

    var tokenRequestCount: Int {
        requestedURLs.filter { $0.path == "/v1/oauth/token" }.count
    }
}

private actor SuspendedRefreshTransport: HTTPTransport {
    private let status: Int
    private var calls = 0
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    init(status: Int = 200) {
        self.status = status
    }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        calls += 1
        let waiters = startContinuations
        startContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let body =
            status == 200
            ? #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}"#
            : #"{"error":"invalid_grant"}"#
        return (Data(body.utf8), response)
    }

    func waitUntilRequestStarts() async {
        if calls > 0 { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func releaseRequest() {
        requestContinuation?.resume()
        requestContinuation = nil
    }

    var requestCount: Int { calls }
}

private actor SuspendedUsageTransport: HTTPTransport {
    private var usageContinuation: CheckedContinuation<Void, Never>?
    private var usageStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var authorizationHeaders: [String] = []

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        if let header = request.value(forHTTPHeaderField: "Authorization") {
            authorizationHeaders.append(header)
        }
        usageStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { usageContinuation = $0 }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = Data(
            #"{"five_hour":{"utilization":40},"seven_day":{"utilization":50}}"#.utf8)
        return (data, response)
    }

    func waitUntilUsageStarts() async {
        guard !usageStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseUsage() {
        let continuation = usageContinuation
        usageContinuation = nil
        continuation?.resume()
    }
}

private final class ManualCredentialPersistenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var savedCredentials: [(String, String)] = []
    private var deletes = 0

    var saveCount: Int { lock.withLock { savedCredentials.count } }
    var deleteCount: Int { lock.withLock { deletes } }
    var savedAccessTokens: [String] { lock.withLock { savedCredentials.map(\.0) } }
    var savedRefreshTokens: [String] { lock.withLock { savedCredentials.map(\.1) } }

    func recordSave(accessToken: String, refreshToken: String) {
        lock.withLock { savedCredentials.append((accessToken, refreshToken)) }
    }

    func recordDelete() {
        lock.withLock { deletes += 1 }
    }
}

private final class MutableOAuthCredentialLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var result: KeychainReadResult<OAuthCredentials>

    init(_ result: KeychainReadResult<OAuthCredentials>) {
        self.result = result
    }

    func load() -> KeychainReadResult<OAuthCredentials> {
        lock.withLock { result }
    }

    func store(_ result: KeychainReadResult<OAuthCredentials>) {
        lock.withLock { self.result = result }
    }
}

private struct OAuthFallbackPipeline: ClaudeMeterPipeline {
    func poll(now: Date, kind _: RefreshKind) async throws -> ParseResult {
        ParseResult(
            snapshot: ClaudeUsageSnapshot(
                parserVersion: "fallback-test",
                createdAt: now,
                source: SourceInfo(cliPath: "/fallback", command: "fallback"),
                limits: LimitInfo(),
                state: SnapshotState(status: .stale, severity: .normal)),
            warnings: [],
            errors: [],
            rawHash: "",
            parserVersion: "fallback-test",
            sourceAttempts: [
                SourceAttempt(source: .cache, outcome: .selected, reason: .cachedSnapshot)
            ])
    }
}

extension OAuthPipelineTests {
    /// Both nested suites mutate `OAuthRefreshGate`'s process-wide static state.
    /// Nesting them under the serialized pipeline suite prevents races with tests
    /// that use the same gate, credential cache, transport, and user defaults.
    @Suite("OAuth refresh gate state")
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
                let withinBackoff = now.addingTimeInterval(
                    OAuthRefreshGate.baseTransientBackoff - 1)
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
}

/// Model-scoped weekly windows are migrating from dedicated `seven_day_<model>`
/// fields into the generic `limits` array, and the flat fields have been observed
/// going null as that happens. Without a fallback the Opus weekly window — often
/// the binding limit on Max — would silently vanish from severity, the menu bar,
/// notifications and the widget, with no error anywhere.
@Suite("Scoped weekly limits from limits[]")
struct ScopedLimitsArrayTests {
    private func decode(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: #require(json.data(using: .utf8)))
    }

    @Test func fillsOpusWhenTheFlatFieldIsAbsent() throws {
        let usage = try decode(
            """
            {"five_hour":{"utilization":10.0},"seven_day":{"utilization":20.0},
             "limits":[{"kind":"weekly_scoped","percent":88.0,
                        "resets_at":"2026-08-10T07:00:00Z",
                        "scope":{"model":{"display_name":"Opus 4.5"}}}]}
            """)
        #expect(usage.sevenDayOpus?.utilization == 88.0)
        #expect(usage.sevenDayOpus?.resetsAt == "2026-08-10T07:00:00Z")
        // It fed the Opus slot, so it must not *also* appear as a scoped row.
        #expect(!usage.scopedWeekly.contains { $0.key == "seven_day_opus" })
    }

    @Test func fillsOpusWhenTheFlatFieldIsExplicitlyNull() throws {
        let usage = try decode(
            """
            {"seven_day_opus":null,
             "limits":[{"kind":"weekly_scoped","percent":42.0,
                        "scope":{"model":{"display_name":"Opus 4.5"}}}]}
            """)
        #expect(usage.sevenDayOpus?.utilization == 42.0)
    }

    /// The flat field is authoritative while it still exists — `limits` only fills
    /// gaps, so today's working path cannot regress.
    @Test func theFlatFieldWinsOverTheArray() throws {
        let usage = try decode(
            """
            {"seven_day_opus":{"utilization":11.0},
             "limits":[{"kind":"weekly_scoped","percent":99.0,
                        "scope":{"model":{"display_name":"Opus 4.5"}}}]}
            """)
        #expect(usage.sevenDayOpus?.utilization == 11.0)
    }

    @Test func addsScopedModelsThatHaveNoFlatField() throws {
        let usage = try decode(
            """
            {"seven_day_sonnet":{"utilization":34.0},
             "limits":[{"kind":"weekly_scoped","percent":7.5,
                        "scope":{"model":{"display_name":"Fable 5"}}}]}
            """)
        #expect(usage.scopedWeekly.map(\.key) == ["seven_day_fable", "seven_day_sonnet"])
        #expect(usage.scopedWeekly.first { $0.key == "seven_day_fable" }?.entry.utilization == 7.5)
    }

    /// A model present in both forms must be listed once, from the flat field.
    @Test func doesNotDuplicateAModelAlreadyCoveredByAFlatField() throws {
        let usage = try decode(
            """
            {"seven_day_sonnet":{"utilization":34.0},
             "limits":[{"kind":"weekly_scoped","percent":99.0,
                        "scope":{"model":{"display_name":"Sonnet 4.5"}}}]}
            """)
        #expect(usage.scopedWeekly.map(\.key) == ["seven_day_sonnet"])
        #expect(usage.scopedWeekly.first?.entry.utilization == 34.0)
    }

    /// `session` / `weekly_all` mirror `five_hour` / `seven_day`; folding them into
    /// scoped rows would double-report the same quota.
    @Test func ignoresNonModelScopedKinds() throws {
        let usage = try decode(
            """
            {"limits":[{"kind":"weekly","percent":50.0},
                       {"kind":"session","percent":60.0},
                       {"kind":"weekly_all","percent":70.0}]}
            """)
        #expect(usage.scopedWeekly.isEmpty)
        #expect(usage.sevenDayOpus == nil)
    }

    @Test func skipsEntriesMissingAModelNameOrPercent() throws {
        let usage = try decode(
            """
            {"limits":[{"kind":"weekly_scoped","percent":50.0},
                       {"kind":"weekly_scoped","percent":50.0,"scope":{"model":{}}},
                       {"kind":"weekly_scoped","scope":{"model":{"display_name":"Opus 4.5"}}},
                       {"kind":"weekly_scoped","percent":50.0,
                        "scope":{"model":{"display_name":""}}}]}
            """)
        #expect(usage.scopedWeekly.isEmpty)
        #expect(usage.sevenDayOpus == nil)
    }

    /// A duplicated model must resolve deterministically, or the popover row would
    /// flip between polls.
    @Test func firstEntryWinsForADuplicatedModel() throws {
        let usage = try decode(
            """
            {"limits":[{"kind":"weekly_scoped","percent":1.0,
                        "scope":{"model":{"display_name":"Fable 5"}}},
                       {"kind":"weekly_scoped","percent":2.0,
                        "scope":{"model":{"display_name":"Fable 5"}}}]}
            """)
        #expect(usage.scopedWeekly.map(\.key) == ["seven_day_fable"])
        #expect(usage.scopedWeekly.first?.entry.utilization == 1.0)
    }

    /// A malformed or absent array must not take the rest of the response down.
    @Test func toleratesAMalformedOrAbsentArray() throws {
        #expect(
            try decode(#"{"seven_day":{"utilization":20.0},"limits":"nope"}"#).sevenDay?
                .utilization == 20.0)
        #expect(try decode(#"{"seven_day":{"utilization":20.0}}"#).sevenDay?.utilization == 20.0)
        #expect(try decode(#"{"seven_day":{"utilization":20.0},"limits":[]}"#).scopedWeekly.isEmpty)
    }

    /// End to end: a model that exists only in `limits[]` must survive the mapping
    /// into display windows, not just the decode.
    @Test func aMigratedScopedModelReachesTheMappedWindows() throws {
        let usage = try decode(
            """
            {"limits":[{"kind":"weekly_scoped","percent":7.5,
                        "resets_at":"2026-08-10T07:00:00Z",
                        "scope":{"model":{"display_name":"Fable 5"}}}]}
            """)
        let scoped = try #require(OAuthPipeline.scopedWindows(from: usage))
        #expect(scoped.map(\.id) == ["seven_day_fable"])
        #expect(scoped.first?.window.percentUsed == 7.5)
        #expect(scoped.first?.displayName == "Fable")
    }
}

/// The 429 deadline the UI reads to render its countdown.
@Suite("OAuth rate-limit deadline", .serialized)
struct OAuthRateLimitDeadlineTests {
    @Test func reportsAnActiveDeadlineAndNothingOtherwise() {
        let now = Date()
        OAuthPipeline.clearRateLimitForTesting()
        defer { OAuthPipeline.clearRateLimitForTesting() }

        #expect(OAuthPipeline.rateLimitedUntil(now: now) == nil)

        let until = now.addingTimeInterval(600)
        OAuthPipeline.recordRateLimit(retryAfter: until, now: now)
        #expect(OAuthPipeline.rateLimitedUntil(now: now) == until)
        // Past the deadline there is nothing to report.
        #expect(OAuthPipeline.rateLimitedUntil(now: until.addingTimeInterval(1)) == nil)
    }

    /// Reading the deadline must not clear the gate — `isRateLimited` mutates as a
    /// side effect, and a UI read happening to land after expiry shouldn't be what
    /// reopens the pipeline's own bookkeeping.
    @Test func readingTheDeadlineDoesNotMutateTheGate() {
        let now = Date()
        OAuthPipeline.clearRateLimitForTesting()
        defer { OAuthPipeline.clearRateLimitForTesting() }

        let until = now.addingTimeInterval(600)
        OAuthPipeline.recordRateLimit(retryAfter: until, now: now)
        _ = OAuthPipeline.rateLimitedUntil(now: until.addingTimeInterval(1))
        // Still armed for a caller asking about the original window.
        #expect(OAuthPipeline.isRateLimited(now: now))
    }
}

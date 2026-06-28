import Foundation
import Testing

@testable import ClaudeMeterCore

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
}

// Serialized: the gate is process-wide static state, so parallel cases would race.
@Suite("OAuthRefreshGate", .serialized)
struct OAuthRefreshGateTests {
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

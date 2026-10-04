import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    @Suite struct RateLimitGateTests {
        private let now = Date.reference()

        @Test(
            arguments: [
                ("120", 120.0), (nil, 60.0), ("0", 60.0), ("-5", 60.0), ("soon", 60.0),
                ("999999", 86_400.0), ("Sun, 04 Oct 2026 12:30:00 GMT", 1_800.0),
                ("Sun, 04 Oct 2026 11:00:00 GMT", 60.0),
            ] as [(String?, TimeInterval)])
        func retryAfterSetsTheBlock(header: String?, seconds: TimeInterval) {
            let gate = RateLimitGate(store: MemoryStore(), now: now)
            #expect(
                gate.recordRateLimit(retryAfter: header, now: now)
                    == now.addingTimeInterval(seconds))
            #expect(gate.blockedUntil(now: now) == now.addingTimeInterval(seconds))
        }

        @Test func aBlockIsNeverShortenedButCanBeExtended() {
            let gate = RateLimitGate(store: MemoryStore(), now: now)
            gate.recordRateLimit(retryAfter: "600", now: now)
            gate.recordRateLimit(retryAfter: "30", now: now.addingTimeInterval(10))
            #expect(gate.blockedUntil(now: now) == now.addingTimeInterval(600))
            gate.recordRateLimit(retryAfter: "900", now: now.addingTimeInterval(10))
            #expect(gate.blockedUntil(now: now) == now.addingTimeInterval(910))
        }

        @Test func theBlockEndsAtItsDeadlineAndClearsTheStore() {
            let store = MemoryStore()
            let gate = RateLimitGate(store: store, now: now)
            gate.recordRateLimit(retryAfter: "60", now: now)
            #expect(store.data(forKey: RateLimitGate.storageKey) != nil)
            #expect(gate.blockedUntil(now: now.addingTimeInterval(59)) != nil)
            #expect(gate.blockedUntil(now: now.addingTimeInterval(60)) == nil)
            #expect(store.data(forKey: RateLimitGate.storageKey) == nil)
        }

        @Test func theDeadlineSurvivesRelaunchAsJSON() throws {
            let store = MemoryStore()
            RateLimitGate(store: store, now: now).recordRateLimit(retryAfter: "300", now: now)

            let data = try #require(store.data(forKey: "claude.rateLimitedUntil"))
            let json = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(
                json == ["recordedAt": "2026-10-04T12:00:00Z", "until": "2026-10-04T12:05:00Z"])

            let relaunched = RateLimitGate(store: store, now: now.addingTimeInterval(100))
            #expect(
                relaunched.blockedUntil(now: now.addingTimeInterval(100))
                    == now.addingTimeInterval(300))
        }

        @Test(arguments: [
            #"{"recordedAt": "2026-10-04T11:00:00Z", "until": "2026-10-04T11:30:00Z"}"#,
            #"{"recordedAt": "2026-10-04T12:00:00Z", "until": "2026-10-06T12:00:00Z"}"#,
            #"{"recordedAt": "2026-10-02T12:00:00Z", "until": "2026-10-05T13:00:00Z"}"#,
            #"{"recordedAt": "2026-10-04T12:00:00Z", "until": "2026-10-04T11:00:00Z"}"#,
            #"{"recordedAt": "2026-10-05T12:00:00Z", "until": "2026-10-05T12:30:00Z"}"#,
            #"{"until": "2026-10-04T12:30:00Z"}"#,
            "corrupt",
        ])
        func invalidOrExpiredRecordsAreRemovedOnLoad(record: String) {
            let store = MemoryStore([RateLimitGate.storageKey: Data(record.utf8)])
            let gate = RateLimitGate(store: store, now: now)
            #expect(gate.blockedUntil(now: now) == nil)
            #expect(store.data(forKey: RateLimitGate.storageKey) == nil)
        }

        @Test func aClockMovedBackMoreThanADayRejectsTheBlock() {
            let gate = RateLimitGate(store: MemoryStore(), now: now)
            gate.recordRateLimit(retryAfter: "3600", now: now)
            #expect(gate.blockedUntil(now: now.addingTimeInterval(-60)) != nil)
            #expect(gate.blockedUntil(now: now.addingTimeInterval(-86_400)) == nil)
        }

        @Test func aBlockAtTheCapSurvivesASmallClockCorrection() {
            let store = MemoryStore()
            let gate = RateLimitGate(store: store, now: now)
            gate.recordRateLimit(retryAfter: "999999", now: now)
            let until = now.addingTimeInterval(86_400)

            #expect(gate.blockedUntil(now: now.addingTimeInterval(-1)) == until)
            #expect(
                RateLimitGate(store: store, now: now.addingTimeInterval(-1))
                    .blockedUntil(now: now.addingTimeInterval(-1)) == until)
            #expect(gate.blockedUntil(now: now.addingTimeInterval(-301)) == nil)
        }
    }

    @Suite struct UsageRequestTests {
        @Test func theRequestMatchesClaudeCode() {
            let request = UsageAPI.request(accessToken: "sk-ant-oat01-token")
            #expect(request.method == .get)
            #expect(
                request.url.absoluteString
                    == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")
            #expect(
                request.headers == [
                    "Authorization": "Bearer sk-ant-oat01-token",
                    "anthropic-beta": "oauth-2025-04-20",
                    "Accept": "application/json",
                    "User-Agent": "claude-cli/2.1.280 (external, cli)",
                ])
            #expect(request.retry == .never)
            #expect(request.deadline == .seconds(15))
            #expect(request.body == nil)
        }

        @Test func statusCodesMapToFailures() async throws {
            let gate = RateLimitGate(store: MemoryStore(), now: .reference())
            func outcome(_ response: HTTPResponse) async -> UsageFailure? {
                let api = UsageAPI(
                    http: FakeHTTPClient { _ in response }, gate: gate, now: { .reference() })
                do {
                    _ = try await api.usage(accessToken: "token")
                    return nil
                } catch {
                    return error as? UsageFailure
                }
            }
            #expect(await outcome(.json(200, ClaudeFixtures.fullUsage)) == nil)
            #expect(await outcome(.json(200, "[]")) == .invalidResponse)
            #expect(await outcome(.json(401, "{}")) == .unauthorized)
            #expect(await outcome(.json(403, "{}")) == .forbidden)
            #expect(await outcome(.json(500, "{}")) == .httpStatus(500))
            #expect(
                await outcome(.json(429, "{}", headers: ["Retry-After": "120"]))
                    == .rateLimited(until: .reference(120)))
            #expect(await outcome(.json(200, "{}")) == .rateLimited(until: .reference(120)))
        }
    }
}

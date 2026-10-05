import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    /// Decision 6: one optional details request, with no effect on quota when it fails.
    @Suite struct CodexResetCreditTests {
        static let details = """
            {"available_count":3,"credits":[
              {"status":"available","title":"Full reset","expires_at":"2026-11-01T00:00:00Z"},
              {"status":"available","title":"No expiry","expires_at":null},
              {"status":"redeemed","title":"Used","expires_at":"2026-11-01T00:00:00Z"}]}
            """

        private static func client(
            details: @escaping @Sendable () async throws -> HTTPResponse
        ) -> FakeHTTPClient {
            FakeHTTPClient { request in
                request.url.path.hasSuffix("/wham/usage")
                    ? .json(200, CodexFixtures.usageWithResets) : try await details()
            }
        }

        @Test func detailsUseTheSameCredentialsAndAttachWhenTheCountMatches() async throws {
            let bed = try CodexTestBed(http: Self.client { .json(200, Self.details) })
            defer { bed.remove() }
            let token = CodexFixtures.accessToken()
            try bed.writeAuth(CodexFixtures.authJSON(accessToken: token))

            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)

            #expect(account.resetAllowance?.available == 3)
            #expect(account.resetAllowance?.resets.map(\.title) == ["Full reset", "No expiry"])
            let requests = bed.http.requests
            #expect(
                requests.map(\.url.path) == [
                    "/backend-api/wham/usage", "/backend-api/wham/rate-limit-reset-credits",
                ])
            for request in requests {
                #expect(request.headers["Authorization"] == "Bearer \(token)")
                #expect(request.headers["ChatGPT-Account-Id"] == "workspace-1")
            }
            let detailsRequest = try #require(requests.last)
            #expect(detailsRequest.headers["OpenAI-Beta"] == "codex-1")
            #expect(detailsRequest.headers["originator"] == "Codex Desktop")
            #expect(detailsRequest.deadline == .seconds(4))
            if case .never = detailsRequest.retry {} else { Issue.record("Details must not retry") }
        }

        @Test(arguments: [401, 403, 404, 429, 500])
        func aFailedDetailsRequestKeepsQuotaAndNeverRecovers(status: Int) async throws {
            let bed = try CodexTestBed(http: Self.client { .json(status, "{}") })
            defer { bed.remove() }
            try bed.writeAuth()
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(account.windows.first?.usedPercent == 12)
            #expect(account.resetAllowance == ResetAllowance(available: 3))
            #expect(account.issue == nil)
            #expect(bed.recovery.calls == 0)
            #expect(bed.http.requests.count == 2)
        }

        /// R3-P-04: a 429 on the details request holds the login until its retry time. The
        /// quota of that refresh stands; the hold lives in memory.
        @Test func aRateLimitedDetailsRequestHoldsTheLogin() async throws {
            let bed = try CodexTestBed(
                http: Self.client { .json(429, "", headers: ["Retry-After": "120"]) })
            defer { bed.remove() }
            try bed.writeAuth()
            let clock = Locked(Date.reference())
            let provider = bed.provider(clock: clock)

            let first = try await provider.fetch(previous: nil)
            let observed = try #require(first.accounts.first)
            #expect(observed.issue == nil)
            #expect(observed.resetAllowance == ResetAllowance(available: 3))

            clock.withLock { $0 = .reference(60) }
            let held = try await provider.fetch(previous: first)
            #expect(bed.http.requests.count == 2)
            let account = try #require(held.accounts.first)
            #expect(account.isStale)
            #expect(account.observedAt == .reference())
            #expect(account.issue?.retryAt == .reference(120))
            #expect(bed.recovery.calls == 0)

            clock.withLock { $0 = .reference(120) }
            _ = try await provider.fetch(previous: held)
            #expect(bed.http.requests.count == 4)
        }

        @Test func aTransportErrorKeepsQuota() async throws {
            let bed = try CodexTestBed(http: Self.client { throw HTTPError.offline })
            defer { bed.remove() }
            try bed.writeAuth()
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(account.resetAllowance == ResetAllowance(available: 3))
        }

        @Test(arguments: [
            #"{"rate_limit":{"primary_window":{"used_percent":1}},"rate_limit_reset_credits":null}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":1}},"rate_limit_reset_credits":{"available_count":0}}"#,
        ])
        func noPositiveCountMeansNoDetailsRequest(body: String) async throws {
            let bed = try CodexTestBed(http: FakeHTTPClient(json: body))
            defer { bed.remove() }
            try bed.writeAuth()
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(bed.http.requests.count == 1)
            #expect(account.resetAllowance?.resets.isEmpty ?? true)
        }

        @Test func theDetailsDeadlineDoesNotWaitForTheTransport() async throws {
            var limits = CodexLimits.standard
            limits.resetDetails = .milliseconds(100)
            let bed = try CodexTestBed(
                http: Self.client {
                    try await Task.sleep(for: .seconds(30))
                    return .json(200, Self.details)
                }, limits: limits)
            defer { bed.remove() }
            try bed.writeAuth()
            let start = ContinuousClock.now
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(ContinuousClock.now - start < .seconds(5))
            #expect(account.windows.first?.usedPercent == 12)
            #expect(account.resetAllowance == ResetAllowance(available: 3))
        }

        @Test func cancellationDuringDetailsCancelsTheFetch() async throws {
            let started = Locked(false)
            let bed = try CodexTestBed(
                http: Self.client {
                    started.withLock { $0 = true }
                    try await Task.sleep(for: .seconds(30))
                    return .json(200, Self.details)
                })
            defer { bed.remove() }
            try bed.writeAuth()
            let provider = bed.provider
            let task = Task { try await provider.fetch(previous: nil) }
            // Cancel only once the details request runs, not after a fixed delay.
            let deadline = ContinuousClock.now + .seconds(10)
            while !started.value, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(started.value)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }
}

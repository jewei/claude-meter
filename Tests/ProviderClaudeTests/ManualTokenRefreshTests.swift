import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// Token refreshes of the manual login: when they go out, how callers share them, and what
    /// stops them.
    @Suite struct ManualTokenRefreshTests {
        @Test func concurrentCallersShareOneRefreshAndTheRealExpiryIsStored() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(30))
            let refreshing = Gate()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url {
                    await refreshing.wait()
                    return .json(200, ClaudeFixtures.rotated)
                }
                return bearer(request) == "new-access" ? .json(200, "{}") : .json(401, "{}")
            }
            let provider = harness.provider(http)

            async let first = provider.fetch(previous: nil)
            async let second = provider.fetch(previous: nil)
            // The second caller joins the request in flight, or uses its rotation; either way
            // the old refresh token is sent once.
            #expect(await refreshing.waitForArrivals())
            refreshing.open()
            let results = try await [first, second]

            #expect(http.requests(to: TokenRefresher.url).count == 1)
            #expect(results.allSatisfy { $0.accounts[0].hasObservation })
            let item = try #require(harness.manualItem())
            #expect(item.accessToken == "new-access")
            #expect(item.refreshToken == "new-refresh")
            #expect(item.expiresAt == .reference(3600))
            #expect(item.connectionID == "connection-1")

            let request = try #require(http.requests(to: TokenRefresher.url).first)
            #expect(request.method == .post)
            #expect(request.headers == ["Content-Type": "application/json"])
            #expect(
                request.body.map { String(decoding: $0, as: UTF8.self) }
                    == #"{"client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e","grant_type":"refresh_token","refresh_token":"old-refresh"}"#
            )
        }

        @Test func http401RefreshesOnceAndRetries() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: nil)
            let http = usageServer(
                ["new-access": ClaudeFixtures.usage(session: 9)],
                tokenResponse: .json(200, ClaudeFixtures.rotated))

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(http.usageTokens == ["old-access", "new-access"])
            #expect(http.requests(to: TokenRefresher.url).count == 1)
            #expect(usage.accounts[0].windows.first?.usedPercent == 9)
            // Pasted tokens name no plan; the card shows the user's plan badge.
            #expect(usage.accounts[0].plan == nil)
        }

        @Test func tokensRejectedAfterARefreshAreNotSentAgain() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: nil)
            // The refreshed token is rejected too; only tokens from a new Connect work.
            let http = usageServer(
                ["fresh": "{}"], tokenResponse: .json(200, ClaudeFixtures.rotated))
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            #expect(http.usageTokens == ["old-access", "new-access"])
            #expect(http.requests(to: TokenRefresher.url).count == 1)
            #expect(first.accounts[0].issue == ClaudeFixtures.manualConnectAgain)

            let second = try await provider.fetch(previous: first)
            #expect(http.requests.count == 3)
            #expect(second.accounts[0].issue == ClaudeFixtures.manualConnectAgain)

            // A new Connect starts over.
            try await provider.connectManually(
                accessToken: "fresh", refreshToken: nil, expiresAt: nil)
            let third = try await provider.fetch(previous: second)
            #expect(third.accounts[0].hasObservation)
        }

        @Test func http403IsNotRefreshed() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: nil)
            let http = FakeHTTPClient { request in
                request.url == TokenRefresher.url
                    ? .json(200, ClaudeFixtures.rotated) : .json(403, #"{"error": "scope"}"#)
            }

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(http.usageTokens == ["old-access"])
            #expect(http.requests(to: TokenRefresher.url).isEmpty)
            #expect(usage.accounts[0].issue == ClaudeFixtures.manualConnectAgain)
        }

        @Test func aShortLifetimeIsRaisedToFiveMinutes() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(10))
            let http = usageServer(
                ["new-access": "{}"],
                tokenResponse: .json(200, #"{"access_token": "new-access", "expires_in": 0}"#))

            _ = try await harness.provider(http).fetch(previous: nil)

            #expect(harness.manualItem()?.expiresAt == .reference(300))
            #expect(harness.manualItem()?.refreshToken == "old-refresh")
        }

        @Test func aRejectedRefreshTokenIsNotSentAgain() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(10))
            let http = usageServer([:], tokenResponse: .json(400, #"{"error": "invalid_grant"}"#))
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            let second = try await provider.fetch(previous: first)

            #expect(http.requests(to: TokenRefresher.url).count == 1)
            #expect(http.usageTokens.isEmpty)
            // Claude Code commands cannot change the manual login; only a new Connect can.
            #expect(second.accounts[0].issue == ClaudeFixtures.manualConnectAgain)
        }

        @Test func temporaryRefreshFailuresBackOff() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(10))
            let http = usageServer([:], tokenResponse: .json(503, "{}"))
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            #expect(
                first.accounts[0].issue?.message
                    == "Could not refresh the Claude tokens. The token server returned HTTP 503.")
            _ = try await provider.fetch(previous: first)
            #expect(http.requests(to: TokenRefresher.url).count == 1)

            harness.advance(300)
            _ = try await provider.fetch(previous: first)
            #expect(http.requests(to: TokenRefresher.url).count == 2)
        }

        @Test func theBackoffDoublesUpToSixHours() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(10))
            let http = usageServer([:], tokenResponse: .json(503, "{}"))
            let provider = harness.provider(http)

            for failure in 1...8 {
                _ = try await provider.fetch(previous: nil)
                #expect(http.requests(to: TokenRefresher.url).count == failure)
                let delay = min(300 * pow(2, Double(failure - 1)), 6 * 60 * 60)
                harness.advance(delay - 1)
                let waiting = try await provider.fetch(previous: nil)
                #expect(waiting.accounts[0].issue?.message == "Retrying the Claude token refresh…")
                #expect(http.requests(to: TokenRefresher.url).count == failure)
                harness.advance(1)
            }
        }

        @Test(arguments: [
            (400, #"{"error": "invalid_grant"}"#, true),
            (401, #"{"error": "Invalid_Grant: token revoked"}"#, true),
            (403, #"{"error": "invalid_request", "error_description": "invalid_grant"}"#, true),
            (500, #"{"error": "invalid_grant"}"#, false),
            (400, #"{"error": "invalid_request"}"#, false),
            (400, "", false),
        ])
        func invalidGrantIsTerminal(status: Int, body: String, isTerminal: Bool) {
            #expect(
                TokenRefresher.isInvalidGrant(status: status, body: Data(body.utf8)) == isTerminal)
        }
    }
}

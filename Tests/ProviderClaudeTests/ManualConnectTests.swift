import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// Connect never spends a refresh token for nothing, and never loses the tokens it got.
    @Suite struct ManualConnectTests {
        private static let rotated =
            #"{"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600}"#

        /// Closes the shared gate for 600 s with one 429.
        private func closeGate(_ provider: ClaudeProvider) async {
            _ = try? await provider.connectManually(
                accessToken: "limited", refreshToken: nil, expiresAt: nil)
        }

        @Test func aClosedGateStopsConnectBeforeItSpendsTheRefreshToken() async throws {
            let harness = try ClaudeHarness(.off)
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url { return .json(200, Self.rotated) }
                return .json(429, "{}", headers: ["Retry-After": "600"])
            }
            let provider = harness.provider(http)
            await closeGate(provider)
            #expect(await provider.rateLimitedUntil() == .reference(600))

            let error = await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "expired", refreshToken: "pasted", expiresAt: .reference(-10))
            }

            #expect(http.requests(to: TokenRefresher.url).isEmpty)
            #expect(
                error?.issue
                    == UsageIssue(
                        "Anthropic is rate-limiting usage checks. Try again in 10 min.",
                        retryAt: .reference(600)))
            #expect(harness.manualItem() == nil)
        }

        @Test func tokensFromARefreshSurviveAFailedCheckForTheNextConnect() async throws {
            let harness = try ClaudeHarness(.off)
            let limited = Locked(true)
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url { return .json(200, Self.rotated) }
                if limited.value { return .json(429, "{}", headers: ["Retry-After": "60"]) }
                return bearer(request) == "new-access" ? .json(200, "{}") : .json(401, "{}")
            }
            let provider = harness.provider(http)

            await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "expired", refreshToken: "pasted", expiresAt: .reference(-10))
            }
            #expect(harness.manualItem() == nil)

            harness.advance(60)
            limited.withLock { $0 = false }
            try await provider.connectManually(
                accessToken: "expired", refreshToken: "pasted", expiresAt: .reference(-10))

            // The pasted refresh token was spent once; the second Connect used its rotation.
            #expect(http.requests(to: TokenRefresher.url).count == 1)
            let item = try #require(harness.manualItem())
            #expect(item.accessToken == "new-access")
            #expect(item.refreshToken == "new-refresh")
        }

        @Test func rejectedRotatedTokensAreForgotten() async throws {
            let harness = try ClaudeHarness(.off)
            let http = usageServer([:], tokenResponse: .json(200, Self.rotated))
            let provider = harness.provider(http)

            for _ in 0..<2 {
                let error = await #expect(throws: ProviderError.self) {
                    try await provider.connectManually(
                        accessToken: "expired", refreshToken: "pasted", expiresAt: .reference(-10))
                }
                #expect(
                    error?.issue.message
                        == "Anthropic rejected these tokens. Check them and try again.")
            }
            #expect(http.requests(to: TokenRefresher.url).count == 2)
        }

        @Test func aDisconnectForgetsARotationThatArrivesAfterIt() async throws {
            let harness = try ClaudeHarness(.off)
            let refreshing = Gate()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url {
                    await refreshing.wait()
                    return .json(200, Self.rotated)
                }
                return bearer(request) == "new-access" ? .json(200, "{}") : .json(401, "{}")
            }
            let provider = harness.provider(http)

            let connect = Task {
                try await provider.connectManually(
                    accessToken: "expired", refreshToken: "pasted", expiresAt: .reference(-10))
            }
            #expect(await refreshing.waitForArrivals())
            try await provider.disconnectManual()
            refreshing.open()

            let error = await #expect(throws: ProviderError.self) { try await connect.value }
            #expect(
                error?.issue.message
                    == "The Claude connection changed while the tokens were checked. Try again.")
            #expect(http.usageTokens.isEmpty)
            // A retry with the same pasted tokens cannot use the tokens that Disconnect forgot.
            try await provider.connectManually(
                accessToken: "expired", refreshToken: "pasted", expiresAt: .reference(-10))
            #expect(http.requests(to: TokenRefresher.url).count == 2)
        }

        @Test func aSharedRefreshKeepsTheConnectionOfEachCaller() async throws {
            let harness = try ClaudeHarness(.manual)
            try harness.storeManual(refreshToken: "shared", expiresAt: .reference(10))
            let refreshing = Gate()
            let committing = Gate()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url {
                    await refreshing.wait()
                    return .json(200, Self.rotated)
                }
                return bearer(request) == "new-access" ? .json(200, "{}") : .json(401, "{}")
            }
            let provider = harness.provider(http)

            // A Connect starts the token request for the refresh token that is also stored.
            let connect = Task {
                try await provider.connectManually(
                    accessToken: "expired", refreshToken: "shared", expiresAt: .reference(-10),
                    isWanted: {
                        await committing.wait()
                        return true
                    })
            }
            #expect(await refreshing.waitForArrivals())
            // A fetch of the stored login joins it once it has read the stored item.
            let fetch = Task { try await provider.fetch(previous: nil) }
            #expect(
                await waitUntil {
                    harness.keychain.readServices.contains(ManualCredentialVault.service)
                })
            // Time to join. A fetch that has not joined yet sends its own request instead, and
            // the owners below are the same.
            try await Task.sleep(for: .milliseconds(50))
            refreshing.open()
            let usage = try await fetch.value
            committing.open()
            try await connect.value

            // The rotation of the stored login keeps its owner, and the Connect gets a new one.
            #expect(usage.accounts[0].hasObservation)
            #expect(
                usage.accounts[0].owner
                    == .identity(Digest.sha256(parts: ["claude", "manual", "connection-1"])))
            #expect(harness.manualItem()?.connectionID != "connection-1")
        }

        @Test func aStaleTokenWithoutExpiryTriesTheRefreshTokenOnce() async throws {
            let harness = try ClaudeHarness(.off)
            let http = usageServer(["new-access": "{}"], tokenResponse: .json(200, Self.rotated))
            let provider = harness.provider(http)

            try await provider.connectManually(
                accessToken: "stale", refreshToken: "pasted", expiresAt: nil)

            #expect(http.usageTokens == ["stale", "new-access"])
            #expect(http.requests(to: TokenRefresher.url).count == 1)
            #expect(harness.manualItem()?.accessToken == "new-access")
        }

        @Test func aRefreshFailureNamesItsReason() async throws {
            let harness = try ClaudeHarness(.off)
            let provider = harness.provider(usageServer([:], tokenResponse: .json(503, "{}")))

            let error = await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "expired", refreshToken: "pasted", expiresAt: .reference(-10))
            }

            #expect(
                error?.issue.message
                    == "Could not refresh the tokens. The token server returned HTTP 503. "
                    + "Try again shortly.")
            #expect(
                ManualLogin.Failure.refreshFailed("HTTP 503").localizedDescription
                    == "The manual Claude token refresh failed. HTTP 503")
        }

        @Test(arguments: [
            (30.0, "in 1 min"), (600, "in 10 min"), (3_600, "in 1 h"), (3_601, "in 1 h 1 min"),
            (86_400, "in 24 h"), (-5, "in 1 min"),
        ])
        func waitTextRoundsUpToWholeMinutes(seconds: TimeInterval, text: String) {
            #expect(ClaudeProvider.waitText(seconds: seconds) == text)
        }
    }
}

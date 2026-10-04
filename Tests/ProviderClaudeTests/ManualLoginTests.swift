import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    @Suite struct ManualLoginTests {
        private static let rotated =
            #"{"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600}"#

        /// A manual harness with a stored login.
        private func connected(expiresAt: Date?, refreshToken: String? = "old-refresh") throws
            -> ClaudeHarness
        {
            let harness = try ClaudeHarness(.manual)
            let stored = ManualCredential(
                accessToken: "old-access", refreshToken: refreshToken, expiresAt: expiresAt,
                subscriptionType: "pro", connectionID: "connection-1")
            harness.keychain.store(
                String(decoding: try JSONEncoder.meter.encode(stored), as: UTF8.self),
                service: ManualCredentialVault.service, account: ManualCredentialVault.account)
            return harness
        }

        @Test func connectVerifiesWithOneRequestThenSaves() async throws {
            let harness = try ClaudeHarness(.manual)
            let http = usageServer(["access": ClaudeFixtures.usage(session: 7)])
            let provider = harness.provider(http)

            try await provider.connectManually(
                accessToken: " access ", refreshToken: " refresh ", expiresAt: .reference(7200))

            #expect(http.usageTokens == ["access"])
            let item = try #require(harness.manualItem())
            #expect(item.accessToken == "access")
            #expect(item.refreshToken == "refresh")
            #expect(item.expiresAt == .reference(7200))
            #expect(!item.connectionID.isEmpty)
            #expect(await provider.manualSignInStatus() == .signedIn)

            let usage = try await provider.fetch(previous: nil)
            #expect(usage.accounts.map(\.id) == ["claude"])
            #expect(usage.accounts[0].name == "default")
            #expect(usage.accounts[0].windows.first?.usedPercent == 7)
            #expect(
                usage.accounts[0].owner
                    == .identity(Digest.sha256(parts: ["claude", "manual", item.connectionID])))
        }

        @Test func aFailedVerificationLeavesTheStoredLoginUnchanged() async throws {
            let harness = try connected(expiresAt: .reference(7200))
            let provider = harness.provider(usageServer([:]))

            let error = await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "bad", refreshToken: nil, expiresAt: nil)
            }
            #expect(
                error?.issue.message == "Anthropic rejected these tokens. Check them and try again."
            )
            #expect(harness.manualItem()?.accessToken == "old-access")
            await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "  ", refreshToken: nil, expiresAt: nil)
            }
        }

        @Test func concurrentCallersShareOneRefreshAndTheRealExpiryIsStored() async throws {
            let harness = try connected(expiresAt: .reference(30))
            let latch = Latch()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url {
                    await latch.wait()
                    return .json(200, Self.rotated)
                }
                return bearer(request) == "new-access" ? .json(200, "{}") : .json(401, "{}")
            }
            let provider = harness.provider(http)

            async let first = provider.fetch(previous: nil)
            async let second = provider.fetch(previous: nil)
            // Both callers wait on the one token request before it answers.
            let deadline = ContinuousClock.now + .seconds(5)
            while await provider.manualLogin.refreshWaiters < 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await provider.manualLogin.refreshWaiters == 2)
            await latch.open()
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
            let harness = try connected(expiresAt: nil)
            let http = usageServer(
                ["new-access": ClaudeFixtures.usage(session: 9)],
                tokenResponse: .json(200, Self.rotated))

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(http.usageTokens == ["old-access", "new-access"])
            #expect(http.requests(to: TokenRefresher.url).count == 1)
            #expect(usage.accounts[0].windows.first?.usedPercent == 9)
            #expect(usage.accounts[0].plan == "Pro")
        }

        @Test func tokensRejectedAfterARefreshAreNotSentAgain() async throws {
            let harness = try connected(expiresAt: nil)
            // The refreshed token is rejected too; only tokens from a new Connect work.
            let http = usageServer(["fresh": "{}"], tokenResponse: .json(200, Self.rotated))
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            #expect(http.usageTokens == ["old-access", "new-access"])
            #expect(http.requests(to: TokenRefresher.url).count == 1)
            #expect(first.accounts[0].issue == Self.connectAgain)

            let second = try await provider.fetch(previous: first)
            #expect(http.requests.count == 3)
            #expect(second.accounts[0].issue == Self.connectAgain)

            // A new Connect starts over.
            try await provider.connectManually(
                accessToken: "fresh", refreshToken: nil, expiresAt: nil)
            let third = try await provider.fetch(previous: second)
            #expect(third.accounts[0].hasObservation)
        }

        @Test func http403IsNotRefreshed() async throws {
            let harness = try connected(expiresAt: nil)
            let http = FakeHTTPClient { request in
                request.url == TokenRefresher.url
                    ? .json(200, Self.rotated) : .json(403, #"{"error": "scope"}"#)
            }

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(http.usageTokens == ["old-access"])
            #expect(http.requests(to: TokenRefresher.url).isEmpty)
            #expect(usage.accounts[0].issue == Self.connectAgain)
        }

        @Test func aShortLifetimeIsRaisedToFiveMinutes() async throws {
            let harness = try connected(expiresAt: .reference(10))
            let http = usageServer(
                ["new-access": "{}"],
                tokenResponse: .json(200, #"{"access_token": "new-access", "expires_in": 0}"#))

            _ = try await harness.provider(http).fetch(previous: nil)

            #expect(harness.manualItem()?.expiresAt == .reference(300))
            #expect(harness.manualItem()?.refreshToken == "old-refresh")
        }

        @Test func aRejectedRefreshTokenIsNotSentAgain() async throws {
            let harness = try connected(expiresAt: .reference(10))
            let http = usageServer([:], tokenResponse: .json(400, #"{"error": "invalid_grant"}"#))
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            let second = try await provider.fetch(previous: first)

            #expect(http.requests(to: TokenRefresher.url).count == 1)
            #expect(http.usageTokens.isEmpty)
            // Claude Code commands cannot change the manual login; only a new Connect can.
            #expect(second.accounts[0].issue == Self.connectAgain)
        }

        @Test func manualTextsGiveManualAdvice() async throws {
            let noRefresh = try connected(expiresAt: .reference(10), refreshToken: nil)
            let expired = try await noRefresh.provider(usageServer([:])).fetch(previous: nil)
            #expect(expired.accounts[0].issue == Self.connectAgain)

            let unreadable = try ClaudeHarness(.manual)
            unreadable.keychain.store(
                "not json", service: ManualCredentialVault.service,
                account: ManualCredentialVault.account)
            let invalid = try await unreadable.provider(usageServer([:])).fetch(previous: nil)
            #expect(
                invalid.accounts[0].issue
                    == UsageIssue(
                        "The saved Claude tokens can't be read. Connect again in Settings.",
                        needsAction: true))

            for usage in [expired, invalid] {
                #expect(usage.accounts[0].issue?.message.contains("claude") == false)
            }
        }

        private static let connectAgain = UsageIssue(
            "The saved Claude tokens no longer work. Connect again in Settings with new tokens.",
            needsAction: true)

        @Test func temporaryRefreshFailuresBackOff() async throws {
            let harness = try connected(expiresAt: .reference(10))
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

        @Test func disconnectWinsOverARefreshInFlight() async throws {
            let harness = try connected(expiresAt: .reference(10))
            let started = Latch()
            let release = Latch()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url {
                    await started.open()
                    await release.wait()
                    return .json(200, Self.rotated)
                }
                return .json(200, "{}")
            }
            let provider = harness.provider(http)

            let fetch = Task { try await provider.fetch(previous: nil) }
            await started.wait()
            try await provider.disconnectManual()
            await release.open()
            let usage = try await fetch.value

            #expect(!usage.accounts[0].hasObservation)
            #expect(
                usage.accounts[0].issue?.message
                    == "The Claude connection changed during the usage check.")
            #expect(harness.manualItem() == nil)
            #expect(await provider.manualSignInStatus() == .signedOut)
            #expect(http.usageTokens.isEmpty)
        }

        @Test func reconnectingChangesTheOwnerOfOldReadings() async throws {
            let harness = try connected(expiresAt: .reference(7200))
            let http = usageServer(["old-access": "{}", "fresh": "{}"])
            let provider = harness.provider(http)
            let usage = try await provider.fetch(previous: nil)
            #expect(await provider.reconcile(usage) == usage)

            try await provider.connectManually(
                accessToken: "fresh", refreshToken: nil, expiresAt: nil)

            #expect(await provider.reconcile(usage) == nil)
        }

        @Test func manualModeWithoutALoginAsksToConnect() async throws {
            let harness = try ClaudeHarness(.manual)
            let usage = try await harness.provider(usageServer([:])).fetch(previous: nil)
            #expect(
                usage.accounts[0].issue
                    == UsageIssue("Connect Claude in Settings to read usage.", needsAction: true))
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

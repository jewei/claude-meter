import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// Disconnect wins over every fetch, refresh, and Connect.
    @Suite struct DisconnectTests {
        @Test func aFetchDuringDisconnectCannotRestoreTheItem() async throws {
            let harness = try ClaudeHarness(.manual)
            try harness.storeManual(expiresAt: .reference(10))
            let deleting = Signal()
            let release = Signal()
            let keychain = ScriptedKeychain(base: harness.keychain) { password in
                guard password == nil else { return }
                deleting.raise()
                release.block()
            }
            let http = FakeHTTPClient { request in
                request.url == TokenRefresher.url
                    ? .json(200, ClaudeFixtures.rotated) : .json(200, "{}")
            }
            let provider = harness.provider(http, keychain: keychain)

            let disconnect = Task { try await provider.disconnectManual() }
            #expect(await deleting.wait())
            // The delete is still running; the old item is still in the Keychain.
            let usage = try await provider.fetch(previous: nil)
            release.raise()
            try await disconnect.value

            #expect(!usage.accounts[0].hasObservation)
            #expect(usage.accounts[0].issue?.message == "Connect Claude in Settings to read usage.")
            #expect(http.requests.isEmpty)
            #expect(harness.manualItem() == nil)
            #expect(keychain.writes == ["delete"])
        }

        @Test func aDisconnectDuringTheRequestStopsTheRefreshAfterHTTP401() async throws {
            let harness = try ClaudeHarness(.manual)
            try harness.storeManual(expiresAt: nil)
            let checking = Gate()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url { return .json(200, ClaudeFixtures.rotated) }
                await checking.wait()
                return bearer(request) == "new-access" ? .json(200, "{}") : .json(401, "{}")
            }
            let provider = harness.provider(http)

            let fetch = Task { try await provider.fetch(previous: nil) }
            #expect(await checking.waitForArrivals())
            try await provider.disconnectManual()
            checking.open()
            let usage = try await fetch.value

            // The deleted login's refresh token is never sent, and no second request goes out.
            #expect(http.requests(to: TokenRefresher.url).isEmpty)
            #expect(http.usageTokens == ["old-access"])
            #expect(!usage.accounts[0].hasObservation)
            #expect(
                usage.accounts[0].issue?.message
                    == "The Claude connection changed during the usage check.")
        }

        @Test func aDisconnectDuringTheRefreshAfterHTTP401SendsNoSecondRequest() async throws {
            let harness = try ClaudeHarness(.manual)
            try harness.storeManual(expiresAt: nil)
            let refreshing = Gate()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url {
                    await refreshing.wait()
                    return .json(200, ClaudeFixtures.rotated)
                }
                return bearer(request) == "new-access" ? .json(200, "{}") : .json(401, "{}")
            }
            let provider = harness.provider(http)

            let fetch = Task { try await provider.fetch(previous: nil) }
            #expect(await refreshing.waitForArrivals())
            try await provider.disconnectManual()
            refreshing.open()
            let usage = try await fetch.value

            #expect(http.usageTokens == ["old-access"])
            #expect(!usage.accounts[0].hasObservation)
            #expect(harness.manualItem() == nil)
        }

        @Test func aNewerConnectDuringTheRequestStopsTheRefreshAfterHTTP401() async throws {
            let harness = try ClaudeHarness(.manual)
            try harness.storeManual(expiresAt: nil)
            let checking = Gate()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url { return .json(200, ClaudeFixtures.rotated) }
                if bearer(request) == "fresh" { return .json(200, "{}") }
                await checking.wait()
                return .json(401, "{}")
            }
            let provider = harness.provider(http)

            let fetch = Task { try await provider.fetch(previous: nil) }
            #expect(await checking.waitForArrivals())
            try await provider.connectManually(
                accessToken: "fresh", refreshToken: nil, expiresAt: nil)
            checking.open()
            let usage = try await fetch.value

            #expect(http.requests(to: TokenRefresher.url).isEmpty)
            #expect(http.usageTokens == ["old-access", "fresh"])
            #expect(!usage.accounts[0].hasObservation)
            #expect(harness.manualItem()?.accessToken == "fresh")
        }

        @Test func aConnectThatOutlivesADisconnectStoresNothing() async throws {
            let harness = try ClaudeHarness(.manual)
            try harness.storeManual(expiresAt: .reference(7200))
            let checking = Gate()
            let http = FakeHTTPClient { request in
                if bearer(request) == "pasted" { await checking.wait() }
                return .json(200, "{}")
            }
            let provider = harness.provider(http)

            let connect = Task {
                try await provider.connectManually(
                    accessToken: "pasted", refreshToken: nil, expiresAt: nil)
            }
            #expect(await checking.waitForArrivals())
            try await provider.disconnectManual()
            checking.open()

            let error = await #expect(throws: ProviderError.self) { try await connect.value }
            #expect(
                error?.issue.message
                    == "The Claude connection changed while the tokens were checked. Try again.")
            #expect(harness.manualItem() == nil)
            #expect(await provider.manualSignInStatus() == .signedOut)
        }

        @Test func aCancelledConnectStoresNothingAndKeepsTheOldLogin() async throws {
            let harness = try ClaudeHarness(.manual)
            try harness.storeManual(expiresAt: .reference(7200))
            let checking = Gate()
            let http = FakeHTTPClient { request in
                if bearer(request) == "pasted" { await checking.wait() }
                return .json(200, "{}")
            }
            let provider = harness.provider(http)

            let connect = Task {
                try await provider.connectManually(
                    accessToken: "pasted", refreshToken: nil, expiresAt: nil)
            }
            #expect(await checking.waitForArrivals())
            await provider.cancelManualConnect()
            checking.open()

            await #expect(throws: ProviderError.self) { try await connect.value }
            #expect(harness.manualItem()?.accessToken == "old-access")
        }

        @Test func aDisconnectDuringTheSaveOfARefreshSendsNoRequest() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(10))
            let saving = Signal()
            let release = Signal()
            let keychain = ScriptedKeychain(base: harness.keychain) { password in
                // Holds the save of the rotation; the delete goes through.
                guard password != nil else { return }
                saving.raise()
                release.block()
            }
            let http = FakeHTTPClient { request in
                request.url == TokenRefresher.url
                    ? .json(200, ClaudeFixtures.rotated) : .json(200, "{}")
            }
            let provider = harness.provider(http, keychain: keychain)

            let fetch = Task { try await provider.fetch(previous: nil) }
            #expect(await saving.wait())
            // The Disconnect forgets the login at once, then waits for the save to end.
            let disconnect = Task { try await provider.disconnectManual() }
            #expect(await eventually { await provider.manualLogin.isDisconnected })
            release.raise()
            let usage = try await fetch.value
            try await disconnect.value

            #expect(http.requests(to: TokenRefresher.url).count == 1)
            #expect(http.usageTokens.isEmpty)
            #expect(!usage.accounts[0].hasObservation)
            #expect(keychain.writes == ["new-access", "delete"])
            #expect(harness.manualItem() == nil)
        }

        @Test func disconnectWinsOverARefreshInFlight() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(10))
            let started = Latch()
            let release = Latch()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url {
                    await started.open()
                    await release.wait()
                    return .json(200, ClaudeFixtures.rotated)
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
    }
}

import Dispatch
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// Disconnect wins over every fetch, refresh, and Connect, and Keychain writes land in order.
    @Suite struct DisconnectTests {
        private static let rotated =
            #"{"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600}"#

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
                request.url == TokenRefresher.url ? .json(200, Self.rotated) : .json(200, "{}")
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
                if request.url == TokenRefresher.url { return .json(200, Self.rotated) }
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
                    return .json(200, Self.rotated)
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
                if request.url == TokenRefresher.url { return .json(200, Self.rotated) }
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

        @Test(arguments: [true, false])
        func aConnectCancelledDuringItsSaveWritesTheOldItemBack(hasOldLogin: Bool) async throws {
            let harness = try ClaudeHarness(.manual)
            if hasOldLogin { try harness.storeManual(expiresAt: .reference(7200)) }
            let saving = Signal()
            let release = Signal()
            let keychain = ScriptedKeychain(base: harness.keychain) { password in
                let token = password.flatMap {
                    try? JSONDecoder.meter.decode(ManualCredential.self, from: $0)
                }?.accessToken
                guard token == "pasted" else { return }
                saving.raise()
                release.block()
            }
            let provider = harness.provider(
                usageServer(["pasted": "{}", "old-access": "{}"]), keychain: keychain)

            let connect = Task {
                try await provider.connectManually(
                    accessToken: "pasted", refreshToken: nil, expiresAt: nil)
            }
            #expect(await saving.wait())
            await provider.cancelManualConnect()
            release.raise()

            let error = await #expect(throws: ProviderError.self) { try await connect.value }
            #expect(
                error?.issue.message
                    == "The Claude connection changed while the tokens were checked. Try again.")
            #expect(keychain.writes == ["pasted", hasOldLogin ? "old-access" : "delete"])
            #expect(harness.manualItem()?.accessToken == (hasOldLogin ? "old-access" : nil))
        }

        @Test(arguments: [[false], [true, false]])
        func aConnectThatIsNoLongerWantedLeavesTheOldItem(answers: [Bool]) async throws {
            let harness = try ClaudeHarness(.manual)
            try harness.storeManual(expiresAt: .reference(7200))
            let provider = harness.provider(usageServer(["pasted": "{}"]))
            let remaining = Locked(answers)

            await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "pasted", refreshToken: nil, expiresAt: nil,
                    isWanted: { remaining.withLock { $0.removeFirst() } })
            }

            // Asked before the save and again after it.
            #expect(remaining.value.isEmpty)
            #expect(harness.manualItem()?.accessToken == "old-access")
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

        @Test func aFailedConnectSaveKeepsTheOldLoginAndItsRotation() async throws {
            let harness = try ClaudeHarness(.manual)
            try harness.storeManual(expiresAt: .reference(10))
            let keychain = ScriptedKeychain(base: harness.keychain) {
                (password: Data?) throws(KeychainError) in
                let token = password.flatMap {
                    try? JSONDecoder.meter.decode(ManualCredential.self, from: $0)
                }?.accessToken
                if token == "pasted" { throw KeychainError.failure(status: -34) }
            }
            let refreshing = Gate()
            let http = FakeHTTPClient { request in
                if request.url == TokenRefresher.url {
                    await refreshing.wait()
                    return .json(200, Self.rotated)
                }
                return .json(200, "{}")
            }
            let provider = harness.provider(http, keychain: keychain)

            let fetch = Task { try await provider.fetch(previous: nil) }
            #expect(await refreshing.waitForArrivals())
            await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "pasted", refreshToken: nil, expiresAt: nil)
            }
            refreshing.open()
            let usage = try await fetch.value

            // The server rotated the old refresh token, so the rotation must be stored.
            #expect(usage.accounts[0].hasObservation)
            let item = try #require(harness.manualItem())
            #expect(item.connectionID == "connection-1")
            #expect(item.refreshToken == "new-refresh")
        }

        @Test func writesLandInOrderAndAnAbandonedWriteNeverLands() async throws {
            let base = FakeKeychain()
            let hung = Signal()
            let release = Signal()
            let calls = Locked(0)
            let keychain = ScriptedKeychain(base: base) { _ in
                let call = calls.withLock { count -> Int in
                    count += 1
                    return count
                }
                guard call == 1 else { return }
                hung.raise()
                release.block()
            }
            let vault = ManualCredentialVault(keychain: keychain, timeout: .milliseconds(100))
            func credential(_ token: String) -> ManualCredential {
                ManualCredential(
                    accessToken: token, refreshToken: nil, expiresAt: nil, connectionID: "c")
            }

            await #expect(throws: TimeoutError.self) {
                try await vault.save(credential("first"), sequence: 1)
            }
            #expect(await hung.wait())
            // Queued behind the hung write, this one times out before it starts.
            await #expect(throws: TimeoutError.self) {
                try await vault.save(credential("second"), sequence: 2)
            }
            release.raise()
            try await vault.save(credential("third"), sequence: 3)

            #expect(keychain.writes == ["first", "third"])
            #expect(try await vault.load() == .found(credential("third")))
        }
    }
}

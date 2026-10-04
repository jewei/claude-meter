import Dispatch
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// The save of a Connect: it is undone when abandoned, never replaces the old login when it
    /// fails, and Keychain writes land in order.
    @Suite struct ConnectSaveTests {
        /// While a Connect has saved its tokens but not decided, a fetch reads them from the
        /// Keychain. It must neither show their quota nor refresh them, whatever the Connect
        /// decides then.
        @Test(arguments: [false, true])
        func aFetchBeforeTheConnectDecidesUsesTheOldLogin(isStored: Bool) async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(7200))
            let http = usageServer(
                [
                    "old-access": ClaudeFixtures.usage(session: 10),
                    "pasted": ClaudeFixtures.usage(session: 70), "new-access": "{}",
                ],
                tokenResponse: .json(200, ClaudeFixtures.rotated))
            let provider = harness.provider(http)
            let first = try await provider.fetch(previous: nil)
            let deciding = Gate()
            let questions = Locked(0)

            let connect = Task {
                try await provider.connectManually(
                    accessToken: "pasted", refreshToken: "pasted-refresh",
                    expiresAt: .reference(100),
                    isWanted: {
                        let question = questions.withLock { count -> Int in
                            count += 1
                            return count
                        }
                        // The second question comes after the save.
                        guard question == 2 else { return true }
                        await deciding.wait()
                        return isStored
                    })
            }
            #expect(await deciding.waitForArrivals())
            #expect(harness.manualItem()?.accessToken == "pasted")
            // The new tokens now expire within 60 s: a fetch that used them would refresh them,
            // then wait for the write lock that the Connect holds to save the rotation.
            harness.advance(50)
            let isFetched = Locked(false)
            let fetch = Task {
                defer { isFetched.withLock { $0 = true } }
                return try await provider.fetch(previous: first)
            }
            #expect(await waitUntil { isFetched.value })
            deciding.open()
            let during = try await fetch.value
            if isStored {
                try await connect.value
            } else {
                await #expect(throws: ProviderError.self) { try await connect.value }
            }

            #expect(during.accounts[0].windows.first?.usedPercent == 10)
            #expect(during.accounts[0].owner == first.accounts[0].owner)
            #expect(http.usageTokens == ["old-access", "pasted", "old-access"])
            #expect(http.requests(to: TokenRefresher.url).isEmpty)
            #expect(harness.manualItem()?.accessToken == (isStored ? "pasted" : "old-access"))
            // Only a stored Connect makes its tokens the login.
            _ = try await provider.fetch(previous: during)
            #expect(http.usageTokens.last == (isStored ? "new-access" : "old-access"))
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
                    return .json(200, ClaudeFixtures.rotated)
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

            // The first write hangs in the Keychain. Only the second uses the short limit.
            let first = Task {
                try await vault.save(credential("first"), sequence: 1, timeout: .seconds(10))
            }
            #expect(await hung.wait())
            // Queued behind the hung write, this one times out before it starts.
            await #expect(throws: TimeoutError.self) {
                try await vault.save(credential("second"), sequence: 2)
            }
            release.raise()
            try await first.value
            // Queued behind both, so it proves that the second never ran.
            try await vault.save(credential("third"), sequence: 3, timeout: .seconds(10))

            #expect(keychain.writes == ["first", "third"])
            let stored = try #require(
                base.storedPassword(
                    service: ManualCredentialVault.service, account: ManualCredentialVault.account))
            #expect(
                try JSONDecoder.meter.decode(ManualCredential.self, from: Data(stored.utf8))
                    == credential("third"))
        }
    }
}

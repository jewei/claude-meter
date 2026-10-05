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
            // A whole fetch, so an ample limit; it ends as soon as the fetch does.
            #expect(await waitUntil(limit: .seconds(30)) { isFetched.value })
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

        @Test func aFetchRepairsAnItemWhoseWriteBackFailed() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(7200))
            let failures = Locked(1)
            let keychain = ScriptedKeychain(base: harness.keychain) {
                (password: Data?) throws(KeychainError) in
                let token = password.flatMap {
                    try? JSONDecoder.meter.decode(ManualCredential.self, from: $0)
                }?.accessToken
                let fails = failures.withLock { count -> Bool in
                    guard token == "old-access", count > 0 else { return false }
                    count -= 1
                    return true
                }
                if fails { throw KeychainError.failure(status: -34) }
            }
            let http = usageServer([
                "old-access": ClaudeFixtures.usage(session: 10), "pasted": "{}",
            ])
            let provider = harness.provider(http, keychain: keychain)
            let first = try await provider.fetch(previous: nil)
            let answers = Locked([true, false])

            // The Connect is abandoned after its save, and the write-back of the old item fails.
            await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "pasted", refreshToken: nil, expiresAt: nil,
                    isWanted: { answers.withLock { $0.removeFirst() } })
            }
            #expect(harness.manualItem()?.accessToken == "pasted")

            // The next fetch uses the old login and writes it back over the abandoned tokens.
            let second = try await provider.fetch(previous: first)
            #expect(second.accounts[0].windows.first?.usedPercent == 10)
            #expect(await waitUntil { keychain.writes == ["pasted", "old-access"] })
            #expect(harness.manualItem()?.accessToken == "old-access")

            // A relaunch forgets the abandoned Connect; the old login is still the login.
            _ = try await harness.provider(http).fetch(previous: second)
            #expect(http.usageTokens == ["old-access", "pasted", "old-access", "old-access"])
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
            let error = await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "pasted", refreshToken: nil, expiresAt: nil)
            }
            #expect(
                error?.issue.message
                    == "Could not save the tokens in the Keychain. The Keychain returned error "
                    + "-34. Try again.")
            refreshing.open()
            let usage = try await fetch.value

            // The server rotated the old refresh token, so the rotation must be stored.
            #expect(usage.accounts[0].hasObservation)
            let item = try #require(harness.manualItem())
            #expect(item.connectionID == "connection-1")
            #expect(item.refreshToken == "new-refresh")
        }

        @Test func aSaveThatTimesOutWhileItRunsIsFollowedByTheOldItem() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(7200))
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
            let limits = HeldTimeLimits()
            let http = usageServer(["pasted": "{}", "old-access": "{}"])
            let provider = harness.provider(
                http, keychain: keychain, keychainTimeLimit: limits.timeLimit)

            let connect = Task {
                try await provider.connectManually(
                    accessToken: "pasted", refreshToken: nil, expiresAt: nil)
            }
            // The save hangs in the Keychain, and only then does its limit end, so Connect
            // reports a failure while the Keychain call still runs.
            #expect(await saving.wait())
            limits.expire()
            let error = await #expect(throws: ProviderError.self) { try await connect.value }
            #expect(
                error?.issue.message.hasPrefix(
                    "Could not save the tokens in the Keychain. Timed out after") == true)
            #expect(harness.manualItem()?.accessToken == "old-access")

            // The save lands late, and the old item is written back after it.
            release.raise()
            #expect(await waitUntil { keychain.writes == ["pasted", "old-access"] })
            #expect(harness.manualItem()?.accessToken == "old-access")
            let usage = try await provider.fetch(previous: nil)
            #expect(usage.accounts[0].hasObservation)
            #expect(http.usageTokens == ["pasted", "old-access"])
        }

        @Test func keychainCallsRunInOrderAndAnAbandonedWriteNeverLands() async throws {
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
            // Only the writes and reads that wait behind the hung write use a short limit.
            let vault = ManualCredentialVault(
                keychain: keychain, timeout: .seconds(5), writeTimeout: .milliseconds(100))
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
            // The old item of a Connect is read after the writes before it, not around them.
            await #expect(throws: TimeoutError.self) {
                try await vault.storedValue(timeout: .milliseconds(100))
            }
            release.raise()
            try await first.value
            // Queued behind both, so it proves that the second never ran.
            try await vault.save(credential("third"), sequence: 3, timeout: .seconds(10))

            #expect(keychain.writes == ["first", "third"])
            let read = try #require(try await vault.storedValue())
            #expect(
                try JSONDecoder.meter.decode(ManualCredential.self, from: read).accessToken
                    == "third")
            let stored = try #require(
                base.storedPassword(
                    service: ManualCredentialVault.service, account: ManualCredentialVault.account))
            #expect(
                try JSONDecoder.meter.decode(ManualCredential.self, from: Data(stored.utf8))
                    == credential("third"))
        }
    }
}

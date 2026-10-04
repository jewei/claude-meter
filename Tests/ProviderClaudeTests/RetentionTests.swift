import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// A temporary failure keeps the reading; only a signed-out or different login drops it.
    @Suite struct RetentionTests {
        private static let truncated = #"{"numStartups": 3, "oauthAccount": {"accountU"#

        private func signedInDefault() throws -> ClaudeHarness {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            harness.signIn(main, token: "main", legacy: true)
            return harness
        }

        @Test func reconcileKeepsTheReadingWhileTheIdentityFileIsBeingWritten() async throws {
            let harness = try signedInDefault()
            let provider = harness.provider(
                usageServer(["main": ClaudeFixtures.usage(session: 3)]))
            let usage = try await provider.fetch(previous: nil)
            #expect(usage.accounts[0].owner?.isPersistable == true)

            try harness.home.write(Self.truncated, to: ".claude.json")

            #expect(await provider.reconcile(usage) == usage)
        }

        @Test func aResponseIsKeptWhenTheIdentityFileIsBeingWrittenAfterIt() async throws {
            let harness = try signedInDefault()
            let truncate = Locked(false)
            let http = FakeHTTPClient { _ in
                if truncate.value { try harness.home.write(Self.truncated, to: ".claude.json") }
                return .json(200, ClaudeFixtures.usage(session: 3))
            }
            let provider = harness.provider(http)
            let first = try await provider.fetch(previous: nil)
            truncate.withLock { $0 = true }
            harness.advance(10)

            let second = try await provider.fetch(previous: first)

            #expect(second.accounts[0].observedAt == .reference(10))
            #expect(second.accounts[0].owner == first.accounts[0].owner)
            #expect(second.accounts[0].issue == nil)
        }

        @Test func noRequestGoesOutWhileTheOwnerIsUnknown() async throws {
            let harness = try signedInDefault()
            let http = usageServer(["main": ClaudeFixtures.usage(session: 3)])
            let provider = harness.provider(http)
            let first = try await provider.fetch(previous: nil)
            try harness.home.write(Self.truncated, to: ".claude.json")
            harness.advance(10)

            let second = try await provider.fetch(previous: first)

            #expect(http.usageTokens == ["main"])
            let kept = second.accounts[0]
            #expect(kept.isStale && kept.observedAt == .reference())
            #expect(
                kept.issue?.message
                    == "Could not read Claude Code's account file. Retrying at the next refresh.")
        }

        @Test func aLockedKeychainKeepsTheUnmappedActiveLogin() async throws {
            let harness = try ClaudeHarness()
            try harness.directory(".claude")
            harness.signIn(service: "Claude Code-credentials-1a2b3c4d", token: "elsewhere")
            let http = usageServer(["elsewhere": ClaudeFixtures.usage(session: 3)])
            let provider = harness.provider(http)
            let usage = try await provider.fetch(previous: nil)
            #expect(usage.account("oauth-ebecf05a")?.hasObservation == true)

            harness.keychain.failure = .unavailable
            #expect(await provider.reconcile(usage) == usage)
            harness.advance(10)
            let locked = try await provider.fetch(previous: usage)

            #expect(locked.accounts.map(\.id) == ["oauth-ebecf05a", "claude"])
            let kept = locked.accounts[0]
            #expect(kept.isStale && kept.observedAt == .reference())
            #expect(
                kept.issue?.message
                    == "Keychain is locked. Unlock your Mac to refresh Claude usage.")
            #expect(http.usageTokens == ["elsewhere"])

            // Once the Keychain answers, a login that is gone drops the account.
            harness.keychain.failure = nil
            try harness.keychain.deletePassword(
                service: "Claude Code-credentials-1a2b3c4d", account: ClaudeHarness.user)
            #expect(await provider.reconcile(locked)?.accounts.map(\.id) == ["claude"])
        }

        @Test func aLockedKeychainWithoutAConfigDirIsNotSignedOut() async throws {
            let harness = try ClaudeHarness()
            harness.signIn(service: ClaudeCodeKeychain.legacyService, token: "main")
            let provider = harness.provider(usageServer(["main": ClaudeFixtures.usage(session: 3)]))
            let usage = try await provider.fetch(previous: nil)
            #expect(usage.accounts.map(\.id) == ["claude"])

            harness.keychain.failure = .unavailable
            #expect(await provider.reconcile(usage) == usage)
            let kept = try await provider.fetch(previous: usage)
            #expect(kept.accounts[0].isStale && kept.accounts[0].hasObservation)

            let error = await #expect(throws: ProviderError.self) {
                try await provider.fetch(previous: nil)
            }
            #expect(
                error?.issue.message
                    == "Keychain is locked. Unlock your Mac to refresh Claude usage.")
            #expect(error?.keepsLastReading == true)
        }

        @Test func aSignOutDuringTheRequestDropsTheResponse() async throws {
            let harness = try signedInDefault()
            let signOut = Locked(false)
            let http = FakeHTTPClient { _ in
                if signOut.value {
                    try harness.signOut(harness.home.path(".claude"), legacy: true)
                }
                return .json(200, ClaudeFixtures.usage(session: 3))
            }
            let provider = harness.provider(http)
            let first = try await provider.fetch(previous: nil)
            signOut.withLock { $0 = true }

            let second = try await provider.fetch(previous: first)

            #expect(!second.accounts[0].hasObservation)
            #expect(
                second.accounts[0].issue?.message
                    == "Claude Code isn't signed in. Open Claude Code and run /login.")
        }

        @Test func configFoldersThatCannotBeListedKeepTheReading() async throws {
            let harness = try signedInDefault()
            let provider = harness.provider(usageServer(["main": "{}"]))
            let usage = try await provider.fetch(previous: nil)
            // Enough folders that listing them takes far longer than the limit.
            for index in 0..<300 { _ = try harness.home.makeDirectory(".claude-\(index)/projects") }
            var limits = ClaudeLimits()
            limits.discovery = .nanoseconds(1)
            let slow = harness.provider(usageServer(["main": "{}"]), limits: limits)

            #expect(await slow.reconcile(usage) == usage)
            let error = await #expect(throws: ProviderError.self) {
                try await slow.fetch(previous: usage)
            }
            #expect(
                error?.issue.message.hasPrefix("Could not read the Claude config folders.") == true)
            #expect(error?.keepsLastReading == true)
        }

        @Test func theLegacyLoginWithoutAConfigDirUsesTheHomeIdentityFile() async throws {
            let harness = try ClaudeHarness()
            try harness.home.write(ClaudeFixtures.identity(account: "acc-1"), to: ".claude.json")
            harness.signIn(service: ClaudeCodeKeychain.legacyService, token: "main")
            let provider = harness.provider(usageServer(["main": "{}", "renewed": "{}"]))

            let usage = try await provider.fetch(previous: nil)
            #expect(usage.accounts.map(\.id) == ["claude"])
            #expect(
                usage.accounts[0].owner
                    == .identity(Digest.sha256(parts: ["claude", "acc-1", "org-1"])))

            // A renewed token keeps the identity owner, so the reading survives.
            harness.signIn(service: ClaudeCodeKeychain.legacyService, token: "renewed")
            #expect(await provider.reconcile(usage) == usage)
        }
    }
}

import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    @Suite struct CodexOwnershipTests {
        /// An HTTP client that rewrites the implicit home's auth file before it answers.
        private static func rewriting(
            _ root: @escaping @Sendable () -> TemporaryDirectory?, to text: String,
            status: Int = 200
        ) -> FakeHTTPClient {
            FakeHTTPClient { _ in
                try root()?.write(text, to: "home/auth.json")
                return .json(status, CodexFixtures.usage)
            }
        }

        /// Decision 4: a changed owner after the response discards the response.
        @Test func aDifferentMemberDuringTheRequestDiscardsTheResponse() async throws {
            let holder = Locked<TemporaryDirectory?>(nil)
            let other = CodexFixtures.authJSON(
                accessToken: CodexFixtures.accessToken(user: "user-2"))
            let bed = try CodexTestBed(http: Self.rewriting({ holder.value }, to: other))
            defer { bed.remove() }
            holder.withLock { $0 = bed.root }
            try bed.writeAuth()

            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)

            #expect(!account.hasObservation)
            #expect(account.issue?.message == CodexError.signInChanged.localizedDescription)
        }

        @Test func tokenRenewalDuringTheRequestKeepsTheResponse() async throws {
            let holder = Locked<TemporaryDirectory?>(nil)
            let renewed = CodexFixtures.authJSON(
                accessToken: CodexFixtures.accessToken(tag: "renewed"))
            let bed = try CodexTestBed(http: Self.rewriting({ holder.value }, to: renewed))
            defer { bed.remove() }
            holder.withLock { $0 = bed.root }
            try bed.writeAuth()
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(account.hasObservation)
        }

        @Test func aCredentialOwnerMustNotChangeDuringADirectRequest() async throws {
            let holder = Locked<TemporaryDirectory?>(nil)
            let bed = try CodexTestBed(
                http: Self.rewriting(
                    { holder.value }, to: CodexFixtures.authJSON(accessToken: "opaque-2")))
            defer { bed.remove() }
            holder.withLock { $0 = bed.root }
            try bed.writeAuth(CodexFixtures.authJSON(accessToken: "opaque-1"))
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(account.issue?.message == CodexError.signInChanged.localizedDescription)
        }

        /// v3 bug 4: recovery that rewrites a file without claims is accepted for that refresh.
        @Test func recoveryThatRewritesAFileWithoutClaimsIsAccepted() async throws {
            let holder = Locked<TemporaryDirectory?>(nil)
            let recovery = FakeRecovery { _, _ in
                try holder.value?.write(
                    CodexFixtures.authJSON(accessToken: "opaque-2"), to: "home/auth.json")
                return CodexRecoveryReply(
                    account: nil, rateLimits: CodexFixtures.value(CodexFixtures.rateLimits))
            }
            let bed = try CodexTestBed(
                http: FakeHTTPClient(status: 401, json: "{}"), recovery: recovery)
            defer { bed.remove() }
            holder.withLock { $0 = bed.root }
            try bed.writeAuth(CodexFixtures.authJSON(accessToken: "opaque-1"))

            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)

            #expect(account.hasObservation)
            #expect(account.owner == .credential(Digest.sha256("opaque-2")))
        }

        @Test func recoveryCannotSwitchTheIdentity() async throws {
            let holder = Locked<TemporaryDirectory?>(nil)
            let recovery = FakeRecovery { _, _ in
                let other = CodexFixtures.authJSON(
                    accessToken: CodexFixtures.accessToken(user: "user-2"))
                try holder.value?.write(other, to: "home/auth.json")
                return CodexRecoveryReply(
                    account: nil, rateLimits: CodexFixtures.value(CodexFixtures.rateLimits))
            }
            let bed = try CodexTestBed(recovery: recovery)
            defer { bed.remove() }
            holder.withLock { $0 = bed.root }
            let expiring = CodexFixtures.accessToken(expiresAt: .reference(10))
            try bed.writeAuth(CodexFixtures.authJSON(accessToken: expiring))
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(recovery.calls == 1)
            #expect(account.issue?.message == CodexError.signInChanged.localizedDescription)
        }

        @Test func aFailureKeepsTheObservationWhileTheOwnerIsSignedIn() async throws {
            let failing = Locked(false)
            let http = FakeHTTPClient { _ in
                failing.value ? .json(500, "{}") : .json(200, CodexFixtures.usage)
            }
            let bed = try CodexTestBed(http: http)
            defer { bed.remove() }
            try bed.writeAuth()
            let first = try await bed.provider.fetch(previous: nil)
            failing.withLock { $0 = true }
            // Codex renewed the token: the identity stays, so the observation stays.
            try bed.writeAuth(
                CodexFixtures.authJSON(accessToken: CodexFixtures.accessToken(tag: "new")))

            let account = try #require(try await bed.provider.fetch(previous: first).accounts.first)

            #expect(account.isStale)
            #expect(account.observedAt == first.accounts.first?.observedAt)
            #expect(account.windows.map(\.usedPercent) == [9, 43])
            #expect(account.issue?.message.contains("HTTP 500") == true)
        }

        @Test func aFailureAfterSignOutOrAPIKeyDropsTheObservation() async throws {
            let bed = try CodexTestBed()
            defer { bed.remove() }
            try bed.writeAuth()
            let first = try await bed.provider.fetch(previous: nil)
            try bed.writeAuth(#"{"auth_mode":"apikey","tokens":{"access_token":"a"}}"#)
            let account = try #require(try await bed.provider.fetch(previous: first).accounts.first)
            #expect(!account.hasObservation)
            #expect(account.windows.isEmpty)
            #expect(account.issue?.message == CodexError.apiKeyOnly.localizedDescription)
        }

        /// Decision 4: a temporary identity read failure is unknown and keeps the observation.
        @Test func anUnreadableAuthFileKeepsTheObservation() async throws {
            let bed = try CodexTestBed()
            defer { bed.remove() }
            try bed.writeAuth()
            let first = try await bed.provider.fetch(previous: nil)
            try FileManager.default.removeItem(at: bed.root.path("home/auth.json"))
            _ = try bed.root.makeDirectory("home/auth.json")

            let reconciled = await bed.provider.reconcile(first)
            #expect(reconciled == first)
            let account = try #require(try await bed.provider.fetch(previous: first).accounts.first)
            #expect(account.isStale)
            #expect(account.observedAt == first.accounts.first?.observedAt)
        }

        @Test func aLoginWithoutAnAuthFileIsShownButNotRetained() async throws {
            let available = Locked(true)
            let recovery = FakeRecovery { _, _ in
                guard available.value else { throw FakeRecovery.Unused() }
                return CodexRecoveryReply(
                    account: nil, rateLimits: CodexFixtures.value(CodexFixtures.rateLimits))
            }
            let bed = try CodexTestBed(recovery: recovery)
            defer { bed.remove() }
            let first = try await bed.provider.fetch(previous: nil)
            #expect(first.accounts.first?.hasObservation == true)
            #expect(first.accounts.first?.owner == nil)

            available.withLock { $0 = false }
            let second = try await bed.provider.fetch(previous: first)
            #expect(second.accounts.first?.hasObservation == false)
        }

        @Test func reconcileDropsChangedOwnersAndRemovedHomes() async throws {
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let extras = Locked([try root.makeDirectory("work")])
            try root.write(CodexFixtures.authJSON(), to: "home/auth.json")
            try root.write(CodexFixtures.authJSON(), to: "work/auth.json")
            let provider = CodexProvider(
                configuration: { CodexConfiguration(extraHomes: extras.value) },
                http: FakeHTTPClient(json: CodexFixtures.usage),
                environment: ["CODEX_HOME": root.path("home").path], home: root.url,
                recovery: FakeRecovery(), now: { .reference() }, limits: .standard)
            let usage = try await provider.fetch(previous: nil)
            #expect(usage.accounts.map(\.name) == ["Codex", "work"])
            #expect(usage.accounts.allSatisfy { $0.sharesLogin })
            #expect(await provider.reconcile(usage) == usage)

            let other = CodexFixtures.authJSON(
                accessToken: CodexFixtures.accessToken(user: "user-2"))
            try root.write(other, to: "work/auth.json")
            #expect(await provider.reconcile(usage)?.accounts.map(\.name) == ["Codex"])

            extras.withLock { $0 = [] }
            try root.write(CodexFixtures.authJSON(), to: "work/auth.json")
            #expect(await provider.reconcile(usage)?.accounts.map(\.name) == ["Codex"])

            try FileManager.default.removeItem(at: root.path("home/auth.json"))
            #expect(await provider.reconcile(usage) == nil)
            #expect(await provider.reconcile(nil) == nil)
        }
    }
}

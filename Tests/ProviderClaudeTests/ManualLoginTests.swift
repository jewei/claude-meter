import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// Manual mode: Connect, the stored login, and the texts of its failures.
    @Suite struct ManualLoginTests {
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
            let harness = try ClaudeHarness.manual(expiresAt: .reference(7200))
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

        @Test func anItemWithUnknownKeysStillLoads() async throws {
            let harness = try ClaudeHarness(.manual)
            harness.keychain.store(
                #"{"accessToken": "a", "refreshToken": "r", "subscriptionType": "pro", "#
                    + #""connectionID": "c"}"#,
                service: ManualCredentialVault.service, account: ManualCredentialVault.account)

            let usage = try await harness.provider(usageServer(["a": "{}"])).fetch(previous: nil)

            #expect(usage.accounts[0].hasObservation)
            #expect(usage.accounts[0].plan == nil)
        }

        @Test func manualTextsGiveManualAdvice() async throws {
            let noRefresh = try ClaudeHarness.manual(expiresAt: .reference(10), refreshToken: nil)
            let expired = try await noRefresh.provider(usageServer([:])).fetch(previous: nil)
            #expect(expired.accounts[0].issue == ClaudeFixtures.manualConnectAgain)

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

        @Test func reconnectingChangesTheOwnerOfOldReadings() async throws {
            let harness = try ClaudeHarness.manual(expiresAt: .reference(7200))
            let http = usageServer(["old-access": "{}", "fresh": "{}"])
            let provider = harness.provider(http)
            let usage = try await provider.fetch(previous: nil)
            #expect(await provider.reconcile(usage) == usage)

            try await provider.connectManually(
                accessToken: "fresh", refreshToken: nil, expiresAt: nil)

            #expect(await provider.reconcile(usage) == nil)
        }

        @Test func theFirstFetchDeletesTheVersion3ManualLogin() async throws {
            let harness = try ClaudeHarness(.off)
            let item = try #require(ManualCredentialVault.version3Item)
            harness.keychain.store(
                #"{"claudeAiOauth": {"accessToken": "a", "refreshToken": "r"}}"#,
                service: item.service, account: item.account)
            let provider = harness.provider(usageServer([:]))

            await #expect(throws: ProviderError.self) { try await provider.fetch(previous: nil) }

            #expect(
                harness.keychain.storedPassword(service: item.service, account: item.account) == nil
            )
        }

        @Test func manualModeWithoutALoginAsksToConnect() async throws {
            let harness = try ClaudeHarness(.manual)
            let usage = try await harness.provider(usageServer([:])).fetch(previous: nil)
            #expect(
                usage.accounts[0].issue
                    == UsageIssue("Connect Claude in Settings to read usage.", needsAction: true))
        }
    }
}

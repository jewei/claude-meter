import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    @Suite struct ConnectionTests {
        @Test func signInStatusReadsAttributesOnly() async throws {
            let harness = try ClaudeHarness(.off)
            let provider = harness.provider(usageServer([:]))
            #expect(await provider.automaticSignInStatus() == .signedOut)
            #expect(await provider.manualSignInStatus() == .signedOut)

            harness.signIn(service: "Claude Code-credentials-12345678", token: "token")
            #expect(await provider.automaticSignInStatus() == .signedIn)
            #expect(harness.keychain.readServices.isEmpty)

            harness.keychain.failure = .unavailable
            #expect(
                await provider.automaticSignInStatus()
                    == .unknown("The Keychain is locked or unavailable."))
            #expect(
                await provider.manualSignInStatus()
                    == .unknown("The Keychain is locked or unavailable."))
        }

        @Test func automaticVerificationReadsTheActiveLoginAndSendsOneRequest() async throws {
            let harness = try ClaudeHarness(.off)
            let http = usageServer(["active": "{}"])
            let provider = harness.provider(http)

            let missing = await #expect(throws: ProviderError.self) {
                try await provider.verifyAutomaticConnection()
            }
            #expect(
                missing?.issue
                    == UsageIssue(
                        "Claude Code credentials were not found in Keychain", needsAction: true))

            harness.signIn(service: "Claude Code-credentials-12345678", token: "active")
            try await provider.verifyAutomaticConnection()
            #expect(http.usageTokens == ["active"])

            harness.keychain.store(
                "not json", service: ClaudeCodeKeychain.legacyService, account: ClaudeHarness.user)
            let invalid = await #expect(throws: ProviderError.self) {
                try await provider.verifyAutomaticConnection()
            }
            #expect(invalid?.issue.message == "Claude Code credentials in Keychain are invalid")
        }

        @Test func automaticVerificationReportsARejectedOrExpiredLogin() async throws {
            let harness = try ClaudeHarness(.off)
            let http = usageServer([:])
            let provider = harness.provider(http)
            let rejected = "Claude Code sign-in was rejected — run `claude auth login`, then retry"

            harness.signIn(service: ClaudeCodeKeychain.legacyService, token: "revoked")
            let error = await #expect(throws: ProviderError.self) {
                try await provider.verifyAutomaticConnection()
            }
            #expect(error?.issue == UsageIssue(rejected, needsAction: true))

            harness.signIn(
                service: ClaudeCodeKeychain.legacyService, token: "old", expiresAt: .reference(10))
            let expired = await #expect(throws: ProviderError.self) {
                try await provider.verifyAutomaticConnection()
            }
            #expect(expired?.issue.message == rejected)
            #expect(http.usageTokens == ["revoked"])
        }

        @Test func verificationArmsAndObeysTheSharedGate() async throws {
            let harness = try ClaudeHarness(.off)
            harness.signIn(service: ClaudeCodeKeychain.legacyService, token: "token")
            let http = FakeHTTPClient { _ in .json(429, "{}", headers: ["Retry-After": "90"]) }
            let provider = harness.provider(http)

            let first = await #expect(throws: ProviderError.self) {
                try await provider.verifyAutomaticConnection()
            }
            #expect(first?.issue.retryAt == .reference(90))
            await #expect(throws: ProviderError.self) {
                try await provider.connectManually(
                    accessToken: "manual", refreshToken: nil, expiresAt: nil)
            }
            #expect(http.requests.count == 1)
            #expect(harness.manualItem() == nil)
        }

        @Test func diagnosticsDescribeSourcesAndTheLastRefresh() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            harness.signIn(main, token: "main", legacy: true)
            let provider = harness.provider(usageServer(["main": "{}"]))
            _ = try await provider.fetch(previous: nil)

            let facts = await provider.diagnostics()
            let values = Dictionary(
                facts.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
            #expect(values["Connection"] == "automatic")
            #expect(values["Config dirs"] == "1 found, 0 disabled")
            #expect(values["Claude Code login"] == "Signed in")
            #expect(values["Rate limited until"] == "Not limited")
            #expect(values["Active login account"] == "claude")
            #expect(values["Account claude"]?.contains("observed") == true)
        }

        @Test func accountsListEnabledAndDisabledConfigDirs() async throws {
            let harness = try ClaudeHarness()
            try harness.directory(".claude")
            try harness.directory(".claude-work")
            let provider = harness.provider(usageServer([:]))

            let accounts = await provider.accounts(
                for: ClaudeConfiguration(connection: .automatic, disabledAccounts: ["claude-work"]))

            #expect(accounts.map(\.id) == ["claude", "claude-work"])
            #expect(accounts.map(\.isEnabled) == [true, false])
        }
    }
}

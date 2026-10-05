import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// Which accounts automatic mode reads, with which login, and what it returns.
    @Suite struct AutomaticRefreshTests {
        @Test func readsEveryAccountWithItsOwnLogin() async throws {
            let harness = try ClaudeHarness.twoAccounts()
            let http = usageServer([
                "main": ClaudeFixtures.fullUsage, "work": ClaudeFixtures.usage(session: 20),
            ])

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(usage.provider == .claude)
            #expect(usage.accounts.map(\.id) == ["claude", "claude-work"])
            #expect(usage.accounts.map(\.name) == ["default", "work"])
            #expect(http.usageTokens == ["main", "work"])
            let main = usage.accounts[0]
            #expect(main.plan == "Max")
            #expect(main.observedAt == .reference())
            #expect(main.attemptedAt == .reference())
            #expect(main.owner == .identity(Digest.sha256(parts: ["claude", "acc-1", "org-1"])))
            #expect(
                main.windows.map(\.id) == [
                    "session", "weekly", "seven_day_opus", "seven_day_sonnet", "extra-usage",
                ])
            #expect(main.balance(.extraUsage)?.amount == Decimal(string: "16.15"))
            #expect(main.resetAllowance?.available == 2)
            #expect(!main.isStale && main.issue == nil && !main.sharesLogin)
            #expect(usage.accounts[1].windows.first?.usedPercent == 20)
        }

        @Test func accountsWithTheSameAccountAndOrganizationShareALogin() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1", organization: "org-1")
            // The same person in another organization has another quota.
            let work = try harness.directory(
                ".claude-work", account: "acc-1", organization: "org-2")
            let copy = try harness.directory(
                ".claude-copy", account: "acc-1", organization: "org-1")
            let team = try harness.directory(
                ".claude-team", account: "acc-2", organization: "org-1")
            harness.signIn(main, token: "main", legacy: true)
            harness.signIn(work, token: "work")
            harness.signIn(copy, token: "copy")
            harness.signIn(team, token: "team")
            let http = usageServer(["main": "{}", "work": "{}", "copy": "{}", "team": "{}"])

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(
                usage.accounts.map(\.id) == [
                    "claude", "claude-copy", "claude-team", "claude-work",
                ])
            #expect(usage.accounts.map(\.sharesLogin) == [true, true, false, false])
        }

        @Test func anUnmappedActiveLoginKeepsItsOwnKeyAndComesFirst() async throws {
            let harness = try ClaudeHarness()
            try harness.directory(".claude")
            harness.signIn(service: "Claude Code-credentials-1a2b3c4d", token: "elsewhere")
            let http = usageServer(["elsewhere": ClaudeFixtures.usage(session: 3)])

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(usage.accounts.map(\.id) == ["oauth-ebecf05a", "claude"])
            #expect(usage.accounts[0].name == "oauth-ebecf05a")
            #expect(usage.accounts[0].owner == .credential(Digest.sha256("elsewhere")))
            #expect(
                usage.accounts[1].issue?.message
                    == "Not signed in. Run `claude`, then /login.")
        }

        @Test func disabledAndBrokenAccountsAreNotRead() async throws {
            let harness = try ClaudeHarness.twoAccounts()
            let team = try harness.directory(".claude-team", account: "acc-3")
            harness.signIn(team, token: "team")
            let gone = harness.home.path("gone/.claude-gone")
            harness.configuration = ClaudeConfiguration(
                connection: .automatic, extraDirectories: [gone], disabledAccounts: ["claude-team"])
            let http = usageServer(["main": "{}", "work": "{}", "team": "{}"])

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(usage.accounts.map(\.id) == ["claude", "claude-gone", "claude-work"])
            #expect(
                usage.accounts[1].issue?.message
                    == "This folder no longer exists. Remove it in Settings.")
            #expect(http.usageTokens == ["main", "work"])
        }

        @Test func noLoginAndNoConfigDirFailsTheProvider() async throws {
            let harness = try ClaudeHarness()
            let error = await #expect(throws: ProviderError.self) {
                try await harness.provider(usageServer([:])).fetch(previous: nil)
            }
            #expect(
                error?.issue.message
                    == "Claude Code isn't signed in. Open Claude Code and run /login.")
            #expect(error?.keepsLastReading == false)
        }

        @Test func connectionOffAsksToConnectAndClearsTheReading() async throws {
            let harness = try ClaudeHarness.twoAccounts()
            let http = usageServer(["main": "{}", "work": "{}"])
            let provider = harness.provider(http)
            let usage = try await provider.fetch(previous: nil)

            harness.configuration = ClaudeConfiguration(connection: .off)
            let error = await #expect(throws: ProviderError.self) {
                try await provider.fetch(previous: usage)
            }
            #expect(
                error?.issue
                    == UsageIssue("Connect Claude in Settings to read usage.", needsAction: true))
            #expect(error?.keepsLastReading == false)
            #expect(await provider.reconcile(usage) == nil)
        }

        @Test func reconcileDropsAccountsThatLeftOrWhoseLoginChanged() async throws {
            let harness = try ClaudeHarness.twoAccounts()
            let team = try harness.directory(".claude-team", account: "acc-3")
            harness.signIn(team, token: "team")
            let provider = harness.provider(
                usageServer(["main": "{}", "work": "{}", "team": "{}"]))
            let usage = try await provider.fetch(previous: nil)
            #expect(await provider.reconcile(usage) == usage)

            // A renewed token keeps an identity owner.
            harness.signIn(harness.home.path(".claude"), token: "main-renewed", legacy: true)
            // Another login in the work dir changes its owner.
            try harness.identify(harness.home.path(".claude-work"), account: "acc-9")
            harness.configuration = ClaudeConfiguration(
                connection: .automatic, disabledAccounts: ["claude-team"])

            let reconciled = await provider.reconcile(usage)
            #expect(reconciled?.accounts.map(\.id) == ["claude"])
            #expect(reconciled?.accounts.first == usage.accounts.first)
        }

        @Test func aCredentialOwnerIsUsedWhenNoIdentityFileExists() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude")
            harness.signIn(main, token: "main", legacy: true)
            let provider = harness.provider(usageServer(["main": "{}"]))

            let usage = try await provider.fetch(previous: nil)
            #expect(usage.accounts[0].owner == .credential(Digest.sha256("main")))

            harness.signIn(main, token: "renewed", legacy: true)
            #expect(await provider.reconcile(usage) == nil)
        }

        @Test func planFallsBackToTheIdentityTier() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.home.makeDirectory(".claude")
            try harness.home.write(
                ClaudeFixtures.identity(account: "acc-1", tier: "default_claude_max_20x"),
                to: ".claude.json")
            harness.signIn(main, token: "main", legacy: true)

            let usage = try await harness.provider(usageServer(["main": "{}"])).fetch(previous: nil)
            #expect(usage.accounts[0].plan == "Max 20x")
        }
    }
}

import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    @Suite struct AutomaticRefreshTests {
        /// `~/.claude` signed in with the legacy item and `~/.claude-work` with its hashed item.
        private func twoAccounts() throws -> ClaudeHarness {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            harness.signIn(main, token: "main", legacy: true)
            harness.signIn(work, token: "work")
            return harness
        }

        @Test func readsEveryAccountWithItsOwnLogin() async throws {
            let harness = try twoAccounts()
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

        @Test func theActiveLoginIsReadEveryTimeAndOthersEveryFiveMinutes() async throws {
            let harness = try twoAccounts()
            let http = usageServer([
                "main": ClaudeFixtures.usage(session: 1), "work": ClaudeFixtures.usage(session: 2),
            ])
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            harness.advance(60)
            let second = try await provider.fetch(previous: first)
            #expect(http.usageTokens == ["main", "work", "main"])
            #expect(second.accounts[0].observedAt == .reference(60))
            #expect(second.accounts[1] == first.accounts[1])

            harness.advance(240)
            let third = try await provider.fetch(previous: second)
            #expect(http.usageTokens == ["main", "work", "main", "main", "work"])
            #expect(third.accounts[1].observedAt == .reference(300))
        }

        @Test func http429StopsTheRefreshAndUnattemptedAccountsKeepTheirAttemptTime() async throws {
            let harness = try twoAccounts()
            let limited = Locked(false)
            let http = FakeHTTPClient { request in
                if limited.value, bearer(request) == "main" {
                    return .json(429, "{}", headers: ["Retry-After": "120"])
                }
                return .json(200, ClaudeFixtures.usage(session: 5))
            }
            let provider = harness.provider(http)
            let first = try await provider.fetch(previous: nil)

            harness.advance(300)
            limited.withLock { $0 = true }
            let second = try await provider.fetch(previous: first)

            #expect(http.usageTokens == ["main", "work", "main"])
            let main = second.accounts[0]
            #expect(main.isStale)
            #expect(main.observedAt == .reference())
            #expect(
                main.issue
                    == UsageIssue(
                        "Anthropic is rate-limiting usage checks.", retryAt: .reference(420)))
            #expect(second.accounts[1] == first.accounts[1])
            #expect(await provider.rateLimitedUntil() == .reference(420))

            // While the gate is closed, no request goes out and the whole refresh fails.
            let error = await #expect(throws: ProviderError.self) {
                try await provider.fetch(previous: second)
            }
            #expect(error?.issue.retryAt == .reference(420))
            #expect(error?.keepsLastReading == true)
            #expect(http.usageTokens.count == 3)

            // After the gate opens, the account that was not attempted is due at once.
            harness.advance(120)
            limited.withLock { $0 = false }
            _ = try await provider.fetch(previous: second)
            #expect(http.usageTokens == ["main", "work", "main", "main", "work"])
        }

        @Test func anAccountWithoutPreviousValueThatWasNotAttemptedShowsTheRateLimit() async throws
        {
            let harness = try twoAccounts()
            let http = FakeHTTPClient { _ in .json(429, "{}", headers: ["Retry-After": "60"]) }

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(http.usageTokens == ["main"])
            #expect(usage.accounts[1].observedAt == nil)
            #expect(usage.accounts[1].attemptedAt == nil)
            #expect(usage.accounts[1].issue?.retryAt == .reference(60))
        }

        @Test func theGateSurvivesANewProviderInstance() async throws {
            let harness = try twoAccounts()
            let http = FakeHTTPClient { _ in .json(429, "{}", headers: ["Retry-After": "600"]) }
            _ = try await harness.provider(http).fetch(previous: nil)

            let relaunched = harness.provider(http)
            #expect(await relaunched.rateLimitedUntil() == .reference(600))
            await #expect(throws: ProviderError.self) { try await relaunched.fetch(previous: nil) }
            #expect(http.usageTokens.count == 1)
        }

        @Test func aResponseThatArrivesAfterTheLoginChangedIsDiscarded() async throws {
            let harness = try twoAccounts()
            let main = harness.home.path(".claude")
            let switched = Locked(false)
            let http = FakeHTTPClient { request in
                if switched.value, bearer(request) == "main" {
                    // Another account signs in while the request is in flight.
                    try harness.identify(main, account: "acc-9")
                }
                return .json(200, ClaudeFixtures.usage(session: 5))
            }
            let provider = harness.provider(http)
            let first = try await provider.fetch(previous: nil)

            switched.withLock { $0 = true }
            harness.advance(10)
            let second = try await provider.fetch(previous: first)

            let account = second.accounts[0]
            #expect(account.observedAt == nil)
            #expect(account.issue?.message == "Claude Code sign-in changed during the usage check.")
            #expect(account.owner == .identity(Digest.sha256(parts: ["claude", "acc-9", "org-1"])))
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
                    == "Credentials missing. Run claude login for this account.")
        }

        @Test func expiredClaudeCodeTokensAreNeverRefreshedOrSent() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            harness.signIn(main, token: "main", legacy: true, expiresAt: .reference(30))
            harness.signIn(work, token: "work", expiresAt: .reference(59))
            let http = usageServer(["main": "{}", "work": "{}"])

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(http.requests.isEmpty)
            #expect(
                usage.accounts[0].issue
                    == UsageIssue(
                        "Claude Code sign-in expired — run `claude login` to restore Claude usage",
                        needsAction: true))
            #expect(
                usage.accounts[1].issue?.message
                    == "Credentials expired. Run claude login for this account.")
            #expect(usage.accounts[1].issue?.needsAction == true)
        }

        @Test func failuresKeepThePreviousObservationAsStaleWithPreciseText() async throws {
            let harness = try twoAccounts()
            let failure = Locked<HTTPError?>(nil)
            let status = Locked(200)
            let http = FakeHTTPClient { _ in
                if let error = failure.value { throw error }
                return .json(status.value, ClaudeFixtures.usage(session: 5))
            }
            let provider = harness.provider(http)
            let first = try await provider.fetch(previous: nil)

            harness.advance(30)
            failure.withLock { $0 = .offline }
            let offline = try await provider.fetch(previous: first)
            let kept = offline.accounts[0]
            #expect(
                kept.isStale && kept.observedAt == .reference()
                    && kept.attemptedAt == .reference(30))
            #expect(
                kept.issue?.message == "Could not refresh Claude usage. The network is unavailable."
            )
            #expect(kept.issue?.needsAction == false)

            failure.withLock { $0 = nil }
            status.withLock { $0 = 500 }
            let serverError = try await provider.fetch(previous: offline)
            #expect(
                serverError.accounts[0].issue?.message == "Anthropic usage check failed (HTTP 500)."
            )

            status.withLock { $0 = 200 }
            let recovered = try await provider.fetch(previous: serverError)
            #expect(!recovered.accounts[0].isStale && recovered.accounts[0].issue == nil)
            #expect(recovered.accounts[0].observedAt == .reference(30))
        }

        @Test func aLockedKeychainKeepsTheReadingAndSigningOutDropsIt() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            harness.signIn(main, token: "main", legacy: true)
            let http = usageServer(["main": "{}"])
            let provider = harness.provider(http)
            let first = try await provider.fetch(previous: nil)

            harness.keychain.failure = .unavailable
            let locked = try await provider.fetch(previous: first)
            #expect(locked.accounts[0].hasObservation && locked.accounts[0].isStale)
            #expect(
                locked.accounts[0].issue?.message
                    == "Keychain is locked — unlock your Mac to refresh Claude usage")

            harness.keychain.failure = nil
            try harness.signOut(main, legacy: true)
            let signedOut = try await provider.fetch(previous: locked)
            #expect(!signedOut.accounts[0].hasObservation)
            #expect(
                signedOut.accounts[0].issue?.message
                    == "Claude Code isn't signed in — run `claude login` to restore Claude usage")
        }

        @Test func disabledAndBrokenAccountsAreNotRead() async throws {
            let harness = try twoAccounts()
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
                    == "Claude Code isn't signed in — run `claude login` to restore Claude usage")
            #expect(error?.keepsLastReading == false)
        }

        @Test func connectionOffAsksToConnectAndClearsTheReading() async throws {
            let harness = try twoAccounts()
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
            let harness = try twoAccounts()
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

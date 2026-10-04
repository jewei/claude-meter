import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// Failures of automatic mode: rate limits, changed logins, expired tokens, and their texts.
    @Suite struct AutomaticFailureTests {
        @Test func http429StopsTheRefreshAndUnattemptedAccountsKeepTheirAttemptTime() async throws {
            let harness = try ClaudeHarness.twoAccounts()
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
            let harness = try ClaudeHarness.twoAccounts()
            let http = FakeHTTPClient { _ in .json(429, "{}", headers: ["Retry-After": "60"]) }

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(http.usageTokens == ["main"])
            #expect(usage.accounts[1].observedAt == nil)
            #expect(usage.accounts[1].attemptedAt == nil)
            #expect(usage.accounts[1].issue?.retryAt == .reference(60))
        }

        @Test func theGateSurvivesANewProviderInstance() async throws {
            let harness = try ClaudeHarness.twoAccounts()
            let http = FakeHTTPClient { _ in .json(429, "{}", headers: ["Retry-After": "600"]) }
            _ = try await harness.provider(http).fetch(previous: nil)

            let relaunched = harness.provider(http)
            #expect(await relaunched.rateLimitedUntil() == .reference(600))
            await #expect(throws: ProviderError.self) { try await relaunched.fetch(previous: nil) }
            #expect(http.usageTokens.count == 1)
        }

        @Test func aResponseThatArrivesAfterTheLoginChangedIsDiscarded() async throws {
            let harness = try ClaudeHarness.twoAccounts()
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

        @Test func expiredClaudeCodeTokensAreNeverRefreshedOrSent() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            harness.signIn(main, token: "main", legacy: true, expiresAt: .reference(30))
            harness.signIn(work, token: "work", expiresAt: .reference(59))
            let http = usageServer(["main": "{}", "work": "{}"])

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(http.requests.isEmpty)
            // Claude Code renews an expired token when it runs, so no sign-in is asked for.
            #expect(
                usage.accounts[0].issue
                    == UsageIssue("Claude Code's token expired. Open Claude Code once to renew it.")
            )
            #expect(
                usage.accounts[1].issue
                    == UsageIssue(
                        "Token expired. Run `CLAUDE_CONFIG_DIR=~/.claude-work claude` once to renew it."
                    ))
        }

        @Test func otherConfigDirsGetAdviceForTheirOwnFolder() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            try harness.directory(".claude-work", account: "acc-2")
            harness.signIn(main, token: "main", legacy: true)
            let spaced = harness.home.path("My Configs/.claude-it's")
            try harness.home.write("{}", to: "My Configs/.claude-it's/settings.json")
            harness.signIn(spaced, token: "spaced")
            harness.configuration = ClaudeConfiguration(
                connection: .automatic, extraDirectories: [spaced])
            let http = usageServer(["main": "{}"])

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(usage.accounts.map(\.id) == ["claude", "claude-its", "claude-work"])
            #expect(
                usage.accounts[1].issue
                    == UsageIssue(
                        #"Sign-in rejected. Run `CLAUDE_CONFIG_DIR=~/'My Configs/.claude-it'\''s' claude`, then /login."#,
                        needsAction: true))
            #expect(
                usage.accounts[2].issue
                    == UsageIssue(
                        "Not signed in. Run `CLAUDE_CONFIG_DIR=~/.claude-work claude`, then /login.",
                        needsAction: true))
        }

        @Test func failuresKeepThePreviousObservationAsStaleWithPreciseText() async throws {
            let harness = try ClaudeHarness.twoAccounts()
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
                    == "The Keychain did not answer. If your Mac is locked, unlock it. "
                    + "Retrying at the next refresh.")

            harness.keychain.failure = nil
            try harness.signOut(main, legacy: true)
            let signedOut = try await provider.fetch(previous: locked)
            #expect(!signedOut.accounts[0].hasObservation)
            #expect(
                signedOut.accounts[0].issue?.message
                    == "Claude Code isn't signed in. Open Claude Code and run /login.")
        }
    }
}

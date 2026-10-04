import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// Which accounts a refresh requests, in which order, and within which time.
    @Suite struct RequestOrderTests {
        /// `~/.claude` and `~/.claude-work`, each with a hashed item. The work item is newer, so
        /// it is Claude Code's active login.
        private func activeWork() throws -> ClaudeHarness {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            harness.signIn(main, token: "main", modifiedAt: .reference())
            harness.signIn(work, token: "work", modifiedAt: .reference(10))
            return harness
        }

        @Test func theActiveLoginIsRequestedFirst() async throws {
            let harness = try activeWork()
            let http = usageServer(["main": "{}", "work": "{}"])
            let provider = harness.provider(http)

            let usage = try await provider.fetch(previous: nil)

            #expect(http.usageTokens == ["work", "main"])
            #expect(usage.accounts.map(\.id) == ["claude", "claude-work"])
            let facts = Dictionary(
                await provider.diagnostics().map { ($0.label, $0.value) },
                uniquingKeysWith: { first, _ in first })
            #expect(facts["Active login account"] == "claude-work")
        }

        @Test func a429NeverStarvesTheActiveLogin() async throws {
            let harness = try activeWork()
            let http = FakeHTTPClient { request in
                bearer(request) == "work"
                    ? .json(200, ClaudeFixtures.usage(session: 4))
                    : .json(429, "{}", headers: ["Retry-After": "60"])
            }

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(http.usageTokens == ["work", "main"])
            #expect(usage.accounts[1].windows.first?.usedPercent == 4)
            #expect(usage.accounts[0].issue?.retryAt == .reference(60))
        }

        @Test func aFailingAccountIsRequestedEveryFiveMinutesOnly() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            harness.signIn(main, token: "main", legacy: true)
            harness.signIn(work, token: "work")
            // The work token is rejected on every request.
            let http = usageServer(["main": "{}"])
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            #expect(first.accounts[1].attemptedAt == .reference())
            harness.advance(60)
            let second = try await provider.fetch(previous: first)
            harness.advance(60)
            let third = try await provider.fetch(previous: second)
            #expect(http.usageTokens == ["main", "work", "main", "main"])

            harness.advance(180)
            _ = try await provider.fetch(previous: third)
            #expect(http.usageTokens == ["main", "work", "main", "main", "main", "work"])
        }

        @Test func anAccountThatSentNoRequestIsReadAgainAtTheNextRefresh() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            harness.signIn(main, token: "main", legacy: true)
            // The work token expired, so no request goes out for it.
            harness.signIn(work, token: "work", expiresAt: .reference(30))
            let http = usageServer(["main": "{}", "work": "{}"])
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            #expect(http.usageTokens == ["main"])
            #expect(first.accounts[1].issue?.message.hasPrefix("Token expired.") == true)
            #expect(first.accounts[1].attemptedAt == nil)

            // The user renews the token: the next refresh reads the account at once.
            harness.advance(60)
            harness.signIn(work, token: "work", expiresAt: .reference(400))
            let second = try await provider.fetch(previous: first)
            #expect(http.usageTokens == ["main", "main", "work"])
            #expect(second.accounts[1].hasObservation)
            #expect(second.accounts[1].attemptedAt == .reference(60))

            // A later failure that sends nothing keeps the time of the last request.
            harness.advance(300)
            let third = try await provider.fetch(previous: second)
            #expect(http.usageTokens == ["main", "main", "work", "main"])
            #expect(third.accounts[1].isStale)
            #expect(third.accounts[1].attemptedAt == .reference(60))
        }

        @Test func theActiveLoginIsReadEveryTimeAndOthersAtEachFiveMinuteTick() async throws {
            let harness = try ClaudeHarness.twoAccounts()
            // Each request takes 2 s of clock time, as a real one does.
            let http = FakeHTTPClient { request in
                harness.advance(2)
                let session = bearer(request) == "main" ? 1.0 : 2.0
                return .json(200, ClaudeFixtures.usage(session: session))
            }
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            #expect(first.accounts[1].attemptedAt == .reference())
            #expect(first.accounts[1].observedAt == .reference(4))
            harness.advance(56)
            let second = try await provider.fetch(previous: first)
            #expect(http.usageTokens == ["main", "work", "main"])
            #expect(second.accounts[0].observedAt == .reference(62))
            #expect(second.accounts[1] == first.accounts[1])

            // The next timer tick, 300 s after the first one. The work account was answered at
            // 4 s, less than 300 s ago, but its attempt started a whole interval ago.
            harness.advance(238)
            let third = try await provider.fetch(previous: second)
            #expect(http.usageTokens == ["main", "work", "main", "main", "work"])
            #expect(third.accounts[1].attemptedAt == .reference(300))
            #expect(third.accounts[1].observedAt == .reference(304))
        }

        @Test(arguments: [(289.0, false), (290, true), (296, true)])
        func aRefreshThatStartsALittleEarlyStillReadsOtherAccounts(
            start: TimeInterval, readsWork: Bool
        ) async throws {
            let harness = try ClaudeHarness.twoAccounts()
            let http = usageServer(["main": "{}", "work": "{}"])
            let provider = harness.provider(http)
            let first = try await provider.fetch(previous: nil)

            harness.advance(start)
            _ = try await provider.fetch(previous: first)

            #expect(http.usageTokens == ["main", "work", "main"] + (readsWork ? ["work"] : []))
        }

        @Test func aTurnedOffActiveLoginLeavesTheDefaultAccountReadEveryTime() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            harness.signIn(main, token: "main", modifiedAt: .reference())
            // Claude Code uses the work login now, but the user turned that account off.
            harness.signIn(work, token: "work", modifiedAt: .reference(10))
            harness.configuration = ClaudeConfiguration(
                connection: .automatic, disabledAccounts: ["claude-work"])
            let http = usageServer(["main": "{}", "work": "{}"])
            let provider = harness.provider(http)

            let first = try await provider.fetch(previous: nil)
            harness.advance(60)
            let second = try await provider.fetch(previous: first)

            #expect(http.usageTokens == ["main", "main"])
            #expect(second.accounts.map(\.id) == ["claude"])
            #expect(second.accounts[0].observedAt == .reference(60))
            let facts = Dictionary(
                await provider.diagnostics().map { ($0.label, $0.value) },
                uniquingKeysWith: { first, _ in first })
            #expect(facts["Active login account"] == "claude-work")
        }

        @Test func everyConfigDirTurnedOffAsksToTurnOneOn() async throws {
            let harness = try ClaudeHarness()
            let work = try harness.directory(".claude-work", account: "acc-2")
            harness.signIn(work, token: "work")
            harness.configuration = ClaudeConfiguration(
                connection: .automatic, disabledAccounts: ["claude-work"])
            let http = usageServer(["work": "{}"])

            let error = await #expect(throws: ProviderError.self) {
                try await harness.provider(http).fetch(previous: nil)
            }

            #expect(
                error?.issue
                    == UsageIssue(
                        "Every Claude config dir is turned off. Turn one on in Settings.",
                        needsAction: true))
            #expect(error?.keepsLastReading == false)
            #expect(http.requests.isEmpty)
        }

        @Test func oneSlowAccountKeepsTheResultsOfTheOthers() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            let team = try harness.directory(".claude-team", account: "acc-3")
            harness.signIn(main, token: "main", legacy: true)
            harness.signIn(team, token: "team")
            harness.signIn(work, token: "work")
            let http = FakeHTTPClient { request in
                // The team account never answers; its deadline cancels the wait.
                if bearer(request) == "team" { try await Task.sleep(for: .seconds(3_600)) }
                return .json(200, ClaudeFixtures.usage(session: 3))
            }
            // Ample time for the accounts that answer, even on a busy machine.
            var limits = ClaudeLimits()
            limits.account = .seconds(2)
            let provider = harness.provider(http, limits: limits)

            let usage = try await provider.fetch(previous: nil)

            #expect(http.usageTokens == ["main", "team", "work"])
            #expect(usage.accounts.map(\.id) == ["claude", "claude-team", "claude-work"])
            #expect(usage.accounts[0].hasObservation && usage.accounts[2].hasObservation)
            #expect(!usage.accounts[1].hasObservation)
            #expect(usage.accounts[1].issue?.message == "The Claude usage check timed out.")
            #expect(usage.accounts[1].attemptedAt == .reference())
        }

        @Test func theEndOfTheBudgetKeepsAccountsThatDidNotStart() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            let team = try harness.directory(".claude-team", account: "acc-3")
            harness.signIn(main, token: "main", legacy: true)
            harness.signIn(team, token: "team")
            harness.signIn(work, token: "work")
            let slow = Locked(false)
            let http = FakeHTTPClient { request in
                // Once slow, the team account never answers; the budget cancels the wait.
                if slow.value, bearer(request) == "team" {
                    try await Task.sleep(for: .seconds(3_600))
                }
                return .json(200, ClaudeFixtures.usage(session: 3))
            }
            // Ample time for a refresh in which every account answers, even on a busy machine.
            var limits = ClaudeLimits()
            limits.refresh = .seconds(3)
            let provider = harness.provider(http, limits: limits)
            let first = try await provider.fetch(previous: nil)

            harness.advance(300)
            slow.withLock { $0 = true }
            let second = try await provider.fetch(previous: first)

            // Team used the rest of the budget, so work was not attempted and keeps its value.
            #expect(http.usageTokens == ["main", "team", "work", "main", "team"])
            #expect(second.accounts[0].observedAt == .reference(300))
            #expect(second.accounts[1].isStale && second.accounts[1].observedAt == .reference())
            #expect(second.accounts[2] == first.accounts[2])
        }
    }
}

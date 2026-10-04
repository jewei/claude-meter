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

        @Test func oneSlowAccountKeepsTheResultsOfTheOthers() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            let work = try harness.directory(".claude-work", account: "acc-2")
            let team = try harness.directory(".claude-team", account: "acc-3")
            harness.signIn(main, token: "main", legacy: true)
            harness.signIn(team, token: "team")
            harness.signIn(work, token: "work")
            let http = FakeHTTPClient { request in
                if bearer(request) == "team" { try await Task.sleep(for: .seconds(30)) }
                return .json(200, ClaudeFixtures.usage(session: 3))
            }
            var limits = ClaudeLimits()
            limits.account = .milliseconds(200)
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
                if slow.value, bearer(request) == "team" {
                    try await Task.sleep(for: .seconds(30))
                }
                return .json(200, ClaudeFixtures.usage(session: 3))
            }
            var limits = ClaudeLimits()
            limits.refresh = .milliseconds(500)
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

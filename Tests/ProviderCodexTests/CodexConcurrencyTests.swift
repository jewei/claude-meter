import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    /// Decision 5: at most three homes at once, and one deadline for the whole fetch.
    @Suite struct CodexConcurrencyTests {
        /// Writes one home per name, each with its own access token tag.
        private static func writeHomes(_ bed: CodexTestBed, _ names: [String]) throws {
            for name in ["home"] + names {
                let token = CodexFixtures.accessToken(tag: name)
                try bed.writeAuth(CodexFixtures.authJSON(accessToken: token), home: name)
            }
        }

        private static func isHome(_ request: HTTPRequest, _ name: String) -> Bool {
            request.headers["Authorization"] == "Bearer \(CodexFixtures.accessToken(tag: name))"
        }

        /// Each request waits until the slots are full, then stays a moment, so the peak does
        /// not depend on how fast a busy machine schedules the homes.
        @Test func atMostThreeHomesRunAtOnce() async throws {
            let running = Locked((now: 0, peak: 0))
            let http = FakeHTTPClient { _ in
                running.withLock {
                    $0.now += 1
                    $0.peak = max($0.peak, $0.now)
                }
                let deadline = ContinuousClock.now + .seconds(10)
                while running.value.now < 3, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try await Task.sleep(for: .milliseconds(50))
                running.withLock { $0.now -= 1 }
                return .json(200, CodexFixtures.usage)
            }
            let names = ["a", "b", "c", "d", "e"]
            let bed = try CodexTestBed(extraHomes: names, http: http)
            defer { bed.remove() }
            try Self.writeHomes(bed, names)

            let usage = try await bed.provider.fetch(previous: nil)

            #expect(usage.accounts.map(\.name) == ["Codex"] + names)
            #expect(usage.accounts.allSatisfy { $0.hasObservation })
            #expect(running.value.peak == 3)
        }

        /// One home that starts at once ends inside the fetch deadline on every path, so a slow
        /// step shows its own message. The number is the one in `codex.md`.
        @Test func theWorstCaseOfOneHomeFitsTheFetchDeadline() {
            let limits = CodexLimits.standard
            #expect(limits.worstCaseFetch <= limits.fetch)
            #expect(limits.worstCaseFetch == .milliseconds(58_250))
            // The store's 90 s safety net covers reconcile (home resolution and one read) too.
            #expect(limits.homeResolution + limits.fileRead + limits.fetch < .seconds(90))
        }

        @Test func theUsageRequestHasItsOwnDeadline() async throws {
            let bed = try CodexTestBed()
            defer { bed.remove() }
            try bed.writeAuth()
            _ = try await bed.provider.fetch(previous: nil)
            #expect(bed.http.requests.first?.deadline == .seconds(15))
        }

        @Test func aStalledHomeDoesNotBlockTheOthers() async throws {
            var limits = CodexLimits.standard
            limits.fetch = .seconds(3)
            let http = FakeHTTPClient { request in
                if Self.isHome(request, "home") { try await Task.sleep(for: .seconds(30)) }
                return .json(200, CodexFixtures.usage)
            }
            let names = ["a", "b", "c", "d"]
            let bed = try CodexTestBed(extraHomes: names, http: http, limits: limits)
            defer { bed.remove() }
            try Self.writeHomes(bed, names)
            let start = ContinuousClock.now

            let usage = try await bed.provider.fetch(previous: nil)

            #expect(ContinuousClock.now - start < .seconds(10))
            #expect(
                usage.accounts.first?.issue?.message == CodexError.timedOut.localizedDescription)
            #expect(usage.accounts.dropFirst().allSatisfy { $0.hasObservation })
        }

        @Test func oneDeadlineCoversEveryHomeAndKeepsObservations() async throws {
            var limits = CodexLimits.standard
            limits.fetch = .seconds(2)
            let stalled = Locked(false)
            let http = FakeHTTPClient { _ in
                if stalled.value { try await Task.sleep(for: .seconds(30)) }
                return .json(200, CodexFixtures.usage)
            }
            let names = ["a", "b", "c", "d", "e"]
            let bed = try CodexTestBed(extraHomes: names, http: http)
            defer { bed.remove() }
            try Self.writeHomes(bed, names)
            // The first fetch has the full deadline, so a busy machine cannot fail it.
            let first = try await bed.provider.fetch(previous: nil)
            #expect(first.accounts.allSatisfy { $0.hasObservation })
            stalled.withLock { $0 = true }
            let start = ContinuousClock.now

            let second = try await bed.provider(limits: limits).fetch(previous: first)

            // At most three homes start before the deadline; the others never start.
            #expect(ContinuousClock.now - start < .seconds(10))
            #expect(bed.http.requests.count <= 6 + 3)
            #expect(second.accounts.count == 6)
            #expect(second.accounts.allSatisfy { $0.isStale && $0.hasObservation })
            #expect(
                second.accounts.allSatisfy {
                    $0.issue?.message == CodexError.timedOut.localizedDescription
                })
        }

        @Test func aBlockedConfigurationFailsTheFetch() async throws {
            var limits = CodexLimits.standard
            limits.fetch = .milliseconds(200)
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let provider = CodexProvider(
                configuration: {
                    try? await Task.sleep(for: .seconds(30))
                    return CodexConfiguration()
                },
                http: FakeHTTPClient(json: CodexFixtures.usage), environment: [:], home: root.url,
                recovery: FakeRecovery(), now: { .reference() }, limits: limits,
                installFolders: [])
            await #expect(throws: ProviderError.self) { try await provider.fetch(previous: nil) }
        }
    }
}

import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    /// After HTTP 429, nothing is sent for the same login before the retry time, so the card's
    /// countdown is true (``RateLimitHold``).
    @Suite struct CodexRateLimitTests {
        private static func limited(retryAfter: String = "120") -> FakeHTTPClient {
            FakeHTTPClient(status: 429, json: "", headers: ["Retry-After": retryAfter])
        }

        @Test func aRateLimitHasItsOwnMessageAndRetryTime() async throws {
            let bed = try CodexTestBed(http: Self.limited())
            defer { bed.remove() }
            try bed.writeAuth()

            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)

            #expect(!account.hasObservation)
            #expect(
                account.issue?.message
                    == "Codex limited the number of requests. Claude Meter will try again later.")
            #expect(account.issue?.retryAt == .reference(120))
            #expect(account.issue?.needsAction == false)
            #expect(bed.recovery.calls == 0)
        }

        @Test func theSameLoginWaitsUntilTheRetryTime() async throws {
            let status = Locked(200)
            let http = FakeHTTPClient { _ in
                .json(status.value, CodexFixtures.usage, headers: ["Retry-After": "120"])
            }
            let bed = try CodexTestBed(http: http)
            defer { bed.remove() }
            try bed.writeAuth()
            let observed = try await bed.provider(now: .reference(-.minutes(10))).fetch(
                previous: nil)
            #expect(observed.accounts.first?.hasObservation == true)
            status.withLock { $0 = 429 }

            let limited = try await bed.provider.fetch(previous: observed)
            let held = try await bed.provider(now: .reference(60)).fetch(previous: limited)

            #expect(http.requests.count == 2)
            let account = try #require(held.accounts.first)
            #expect(account.isStale)
            #expect(account.observedAt == observed.accounts.first?.observedAt)
            #expect(account.issue?.retryAt == .reference(120))
            #expect(account.attemptedAt == .reference(60))
            #expect(bed.recovery.calls == 0)

            _ = try await bed.provider(now: .reference(120)).fetch(previous: held)
            #expect(http.requests.count == 3)
        }

        /// A first 429 has no observation to keep, and still holds the next request.
        @Test func aRateLimitWithoutAnObservationHoldsToo() async throws {
            let bed = try CodexTestBed(http: Self.limited())
            defer { bed.remove() }
            try bed.writeAuth()

            let limited = try await bed.provider.fetch(previous: nil)
            _ = try await bed.provider(now: .reference(60)).fetch(previous: limited)

            #expect(bed.http.requests.count == 1)
        }

        /// A home that did not finish in time sent nothing for the held login, so the hold
        /// stays. A sign-out ends it.
        @Test func aHomeThatTimedOutKeepsTheHold() async throws {
            let bed = try CodexTestBed(http: Self.limited())
            defer { bed.remove() }
            try bed.writeAuth()
            let limited = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            let home = try #require(await bed.homes().first)

            let timedOut = CodexAttempt(home: home, outcome: .timedOut, attemptedAt: .reference(60))
                .account(previous: limited)
            let signedOut = CodexAttempt(
                home: home,
                outcome: .init(kind: .failed(.apiKeyOnly, status: .signedOut)),
                attemptedAt: .reference(60)
            ).account(previous: limited)

            #expect(timedOut.issue?.retryAt == .reference(120))
            #expect(timedOut.owner == limited.owner)
            #expect(timedOut.attemptedAt == .reference(60))
            #expect(signedOut.issue?.message == CodexError.apiKeyOnly.localizedDescription)
            #expect(signedOut.owner == nil)
        }

        /// A 429 belongs to the login that sent the request. A `codex login` as another user
        /// during the request is a sign-in change, and the new login sends at once.
        @Test func aLoginChangeDuringALimitedRequestDoesNotHoldTheNewLogin() async throws {
            let holder = Locked<TemporaryDirectory?>(nil)
            let calls = Locked(0)
            let other = CodexFixtures.authJSON(
                accessToken: CodexFixtures.accessToken(user: "user-2"))
            let http = FakeHTTPClient { _ in
                let call = calls.withLock { count -> Int in
                    count += 1
                    return count
                }
                guard call == 1 else { return .json(200, CodexFixtures.usage) }
                try holder.value?.write(other, to: "home/auth.json")
                return .json(429, "", headers: ["Retry-After": "120"])
            }
            let bed = try CodexTestBed(http: http)
            defer { bed.remove() }
            holder.withLock { $0 = bed.root }
            try bed.writeAuth()

            let changed = try await bed.provider.fetch(previous: nil)
            let account = try #require(changed.accounts.first)
            #expect(account.issue?.message == CodexError.signInChanged.localizedDescription)
            #expect(account.issue?.retryAt == nil)
            #expect(
                account.owner
                    == .identity(Digest.sha256(parts: ["codex", "user-2", "workspace-1"])))

            let next = try await bed.provider(now: .reference(60)).fetch(previous: changed)
            #expect(http.requests.count == 2)
            #expect(next.accounts.first?.hasObservation == true)
        }

        /// An auth file that cannot be read now sends nothing, so the hold of the last login
        /// stays until the file can be read again.
        @Test func anAuthFileThatCannotBeReadKeepsTheHold() async throws {
            let bed = try CodexTestBed(http: Self.limited())
            defer { bed.remove() }
            try bed.writeAuth()
            let limited = try await bed.provider.fetch(previous: nil)
            try FileManager.default.removeItem(at: bed.root.path("home/auth.json"))
            _ = try bed.root.makeDirectory("home/auth.json")

            let unreadable = try await bed.provider(now: .reference(30)).fetch(previous: limited)
            try FileManager.default.removeItem(at: bed.root.path("home/auth.json"))
            try bed.writeAuth()
            _ = try await bed.provider(now: .reference(60)).fetch(previous: unreadable)

            #expect(unreadable.accounts.first?.issue?.retryAt == .reference(120))
            #expect(unreadable.accounts.first?.owner == limited.accounts.first?.owner)
            #expect(bed.http.requests.count == 1)
            #expect(bed.recovery.calls == 0)
        }

        /// A capped retry time and the check that keeps it read one clock, so a one-hour 429
        /// is kept even though a real clock moves between reads (review F-R-01).
        @Test(arguments: ["3600", "86400"])
        func aOneHourRateLimitHoldsTheNextHomeWithAMovingClock(retryAfter: String) async throws {
            let calls = Locked(0)
            let http = FakeHTTPClient { _ in
                let call = calls.withLock { count -> Int in
                    count += 1
                    return count
                }
                return call == 1
                    ? .json(429, "", headers: ["Retry-After": retryAfter])
                    : .json(200, CodexFixtures.usage)
            }
            var limits = CodexLimits.standard
            limits.concurrentHomes = 1
            let bed = try CodexTestBed(extraHomes: ["work"], http: http, limits: limits)
            defer { bed.remove() }
            try bed.writeAuth()
            try bed.writeAuth(home: "work")
            let usage = try await bed.providerWithMovingClock(limits: limits).fetch(previous: nil)
            #expect(http.requests.count == 1)
            #expect(usage.accounts.allSatisfy { $0.issue?.retryAt != nil })
        }

        /// R3-P-05 and R5-P-01: the limit belongs to the login, so another home with the same
        /// login waits too, also one that starts after the 429 in the same fetch. A home with
        /// another login sends.
        @Test func aRateLimitHoldsEveryHomeOfTheSameLogin() async throws {
            let calls = Locked(0)
            let http = FakeHTTPClient { _ in
                let call = calls.withLock { count -> Int in
                    count += 1
                    return count
                }
                return call == 1
                    ? .json(429, "", headers: ["Retry-After": "120"])
                    : .json(200, CodexFixtures.usage)
            }
            var limits = CodexLimits.standard
            limits.concurrentHomes = 1
            let bed = try CodexTestBed(extraHomes: ["work", "other"], http: http, limits: limits)
            defer { bed.remove() }
            try bed.writeAuth()
            try bed.writeAuth(home: "work")
            try bed.writeAuth(
                CodexFixtures.authJSON(accessToken: CodexFixtures.accessToken(user: "user-2")),
                home: "other")
            // One home at a time: `work` starts after the 429 of the first home.
            let first = try await bed.provider.fetch(previous: nil)
            #expect(http.requests.count == 2)
            #expect(
                first.accounts.map { $0.issue?.retryAt } == [.reference(120), .reference(120), nil])
            let limited = try #require(first.accounts.first)
            let work = try #require(first.accounts.dropFirst().first)
            #expect(!work.hasObservation)
            #expect(work.issue == limited.issue)
            #expect(work.owner == limited.owner)
            #expect(work.owner != nil)
            #expect(first.accounts.last?.hasObservation == true)

            let held = try await bed.provider(limits: limits, now: .reference(60))
                .fetch(previous: first)

            #expect(http.requests.count == 3)
            #expect(
                held.accounts.map { $0.issue?.retryAt } == [.reference(120), .reference(120), nil])
            #expect(held.accounts.dropFirst().first?.owner == limited.owner)
            #expect(held.accounts.last?.hasObservation == true)
        }

        /// R4-P-01: a 429 is kept as soon as Codex answers. A fetch that is cancelled after it,
        /// here while another home still waits, holds the login all the same, so the next fetch
        /// sends nothing for it before the retry time.
        @Test func aRateLimitHoldsAfterTheFetchIsCancelled() async throws {
            let gate = Gate()
            let slowToken = CodexFixtures.accessToken(user: "user-2")
            let http = FakeHTTPClient { request in
                guard request.headers["Authorization"] == "Bearer \(slowToken)" else {
                    return .json(429, "", headers: ["Retry-After": "120"])
                }
                await gate.wait()
                return .json(200, CodexFixtures.usage)
            }
            let limitedRequests = {
                http.requests.filter { $0.headers["Authorization"] != "Bearer \(slowToken)" }.count
            }
            var limits = CodexLimits.standard
            limits.concurrentHomes = 1
            let bed = try CodexTestBed(extraHomes: ["work"], http: http, limits: limits)
            defer { bed.remove() }
            try bed.writeAuth()
            try bed.writeAuth(CodexFixtures.authJSON(accessToken: slowToken), home: "work")
            let clock = Locked(Date.reference())
            let provider = bed.provider(clock: clock, limits: limits)

            let task = Task { try await provider.fetch(previous: nil) }
            // One home at a time: the second home waits only after the first got its 429.
            #expect(await gate.waitForArrivals())
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            gate.open()

            clock.withLock { $0 = .reference(60) }
            let held = try await provider.fetch(previous: nil)
            #expect(limitedRequests() == 1)
            let limited = try #require(held.accounts.first)
            #expect(limited.issue?.retryAt == .reference(120))
            #expect(limited.owner != nil)
            #expect(held.accounts.last?.hasObservation == true)

            clock.withLock { $0 = .reference(120) }
            _ = try await provider.fetch(previous: held)
            #expect(limitedRequests() == 2)
        }

        @Test func anotherLoginIsNotHeld() async throws {
            let bed = try CodexTestBed(http: Self.limited())
            defer { bed.remove() }
            try bed.writeAuth()
            let limited = try await bed.provider.fetch(previous: nil)

            try bed.writeAuth(
                CodexFixtures.authJSON(accessToken: CodexFixtures.accessToken(user: "user-2")))
            _ = try await bed.provider(now: .reference(60)).fetch(previous: limited)

            #expect(bed.http.requests.count == 2)
        }

        /// A wrong `Retry-After` cannot stop requests for more than one hour.
        @Test func aRateLimitHoldsAtMostOneHour() async throws {
            let bed = try CodexTestBed(http: Self.limited(retryAfter: "86400"))
            defer { bed.remove() }
            try bed.writeAuth()

            let limited = try await bed.provider.fetch(previous: nil)
            #expect(limited.accounts.first?.issue?.retryAt == .reference(.hours(1)))
            let held = try await bed.provider(now: .reference(.hours(1) - 1)).fetch(
                previous: limited)
            #expect(bed.http.requests.count == 1)
            _ = try await bed.provider(now: .reference(.hours(1))).fetch(previous: held)
            #expect(bed.http.requests.count == 2)
        }

        /// Other statuses have no countdown, because nothing waits for them.
        @Test func otherStatusesHoldNothing() async throws {
            let bed = try CodexTestBed(
                http: FakeHTTPClient(status: 503, json: "", headers: ["Retry-After": "120"]))
            defer { bed.remove() }
            try bed.writeAuth()

            let failed = try await bed.provider.fetch(previous: nil)
            _ = try await bed.provider(now: .reference(60)).fetch(previous: failed)

            #expect(failed.accounts.first?.issue?.retryAt == nil)
            #expect(bed.http.requests.count == 2)
        }
    }
}

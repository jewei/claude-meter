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

import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct RateLimitHoldsTests {
    private let alice = AccountOwner.identity("alice")
    private let bob = AccountOwner.identity("bob")

    @Test func noHoldStopsNothing() {
        #expect(RateLimitHolds().retryAt(for: alice, now: .reference()) == nil)
    }

    @Test func aHoldStopsOnlyItsOwnLoginUntilItsRetryTime() {
        var holds = RateLimitHolds()
        holds.record(RateLimitHold(owner: alice, retryAt: .reference(120)), now: .reference())

        #expect(holds.retryAt(for: alice, now: .reference(119)) == .reference(120))
        #expect(holds.retryAt(for: alice, now: .reference(120)) == nil)
        #expect(holds.retryAt(for: bob, now: .reference()) == nil)
    }

    /// R5-P-02: a 429 for another login never ends the hold of the first login.
    @Test func eachLoginKeepsItsOwnHold() {
        var holds = RateLimitHolds()
        holds.record(RateLimitHold(owner: alice, retryAt: .reference(120)), now: .reference())
        holds.record(RateLimitHold(owner: bob, retryAt: .reference(90)), now: .reference(30))

        #expect(holds.retryAt(for: alice, now: .reference(60)) == .reference(120))
        #expect(holds.retryAt(for: bob, now: .reference(60)) == .reference(90))
    }

    /// Two 429s of one login that arrive close together, such as from two Codex homes: the
    /// later retry time wins, whatever the order.
    @Test func theLaterRetryTimeOfOneLoginWins() {
        var holds = RateLimitHolds()
        holds.record(RateLimitHold(owner: alice, retryAt: .reference(120)), now: .reference())
        holds.record(RateLimitHold(owner: alice, retryAt: .reference(60)), now: .reference())
        #expect(holds.retryAt(for: alice, now: .reference()) == .reference(120))

        holds.record(RateLimitHold(owner: alice, retryAt: .reference(180)), now: .reference())
        #expect(holds.retryAt(for: alice, now: .reference()) == .reference(180))
    }

    /// A hold that ended, also one more than one hour ahead after the clock moved back, never
    /// keeps a newer 429 of the same login from holding.
    @Test func anEndedHoldGivesWayToANewOne() {
        var holds = RateLimitHolds()
        holds.record(RateLimitHold(owner: alice, retryAt: .reference(.hours(1))), now: .reference())
        holds.record(RateLimitHold(owner: alice, retryAt: .reference(60)), now: .reference(-60))

        #expect(holds.retryAt(for: alice, now: .reference(-60)) == .reference(60))
    }

    /// The 1-hour rule of ``RateLimitHold``: a time more than one hour ahead holds nothing.
    @Test func aRetryTimeMoreThanOneHourAheadHoldsNothing() {
        var holds = RateLimitHolds()
        holds.record(RateLimitHold(owner: alice, retryAt: .reference(.hours(1))), now: .reference())

        #expect(holds.retryAt(for: alice, now: .reference()) == .reference(.hours(1)))
        #expect(holds.retryAt(for: alice, now: .reference(-1)) == nil)

        var archived = RateLimitHolds()
        archived.record(
            RateLimitHold(owner: alice, retryAt: .reference(.days(2))), now: .reference())
        #expect(archived.retryAt(for: alice, now: .reference()) == nil)
    }

    /// Holds that ended are dropped, so memory does not grow with each login seen.
    @Test func endedHoldsAreDropped() {
        var holds = RateLimitHolds()
        holds.record(RateLimitHold(owner: alice, retryAt: .reference(60)), now: .reference())
        holds.record(RateLimitHold(owner: bob, retryAt: .reference(180)), now: .reference(120))

        var expected = RateLimitHolds()
        expected.record(RateLimitHold(owner: bob, retryAt: .reference(180)), now: .reference(120))
        #expect(holds == expected)
    }
}

import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct RateLimitHoldTests {
    private let alice = AccountOwner.identity("alice")
    private let bob = AccountOwner.identity("bob")

    @Test func theRetryTimeIsTheServerDelayAtMostOneHourLater() {
        #expect(RateLimitHold.retryAt(delay: 120, now: .reference()) == .reference(120))
        #expect(RateLimitHold.retryAt(delay: 3_600, now: .reference()) == .reference(3_600))
        #expect(RateLimitHold.retryAt(delay: 366 * 86_400, now: .reference()) == .reference(3_600))
        #expect(RateLimitHold.retryAt(delay: nil, now: .reference()) == nil)
        #expect(RateLimitHold.retryAt(delay: 0, now: .reference()) == nil)
    }

    @Test func aHoldStopsOnlyItsOwnLoginUntilItsRetryTime() {
        let hold = RateLimitHold(owner: alice, retryAt: .reference(120))
        #expect(hold.holds(alice, now: .reference()))
        #expect(hold.holds(alice, now: .reference(119)))
        #expect(!hold.holds(alice, now: .reference(120)))
        #expect(!hold.holds(bob, now: .reference()))
    }

    /// The rule never keeps a time more than one hour ahead. Such a time comes from a clock
    /// that moved back, or from a reading that an older version archived, and holds nothing.
    @Test func aRetryTimeMoreThanOneHourAheadHoldsNothing() {
        let capped = RateLimitHold(owner: alice, retryAt: .reference(3_600))
        #expect(capped.holds(alice, now: .reference()))
        #expect(!capped.holds(alice, now: .reference(-1)))
        let archived = RateLimitHold(owner: alice, retryAt: .reference(.days(366)))
        #expect(!archived.holds(alice, now: .reference()))
    }

    @Test func anAccountHoldsTheRequestsOfItsOwnerOnly() {
        let issue = UsageIssue("Limited.", retryAt: .reference(120))
        let limited = AccountUsage(
            id: "a", name: "A", observedAt: .reference(-60), issue: issue, owner: alice)
        #expect(limited.rateLimitHold(for: alice, now: .reference()) == issue)
        #expect(limited.rateLimitHold(for: bob, now: .reference()) == nil)
        #expect(limited.rateLimitHold(for: alice, now: .reference(120)) == nil)

        var noRetryTime = limited
        noRetryTime.issue = UsageIssue("Failed.")
        #expect(noRetryTime.rateLimitHold(for: alice, now: .reference()) == nil)

        var noOwner = limited
        noOwner.owner = nil
        #expect(noOwner.rateLimitHold(for: alice, now: .reference()) == nil)
    }

    /// A refresh that sends nothing keeps the hold while the login can still be the one that
    /// got the 429. A sign-out or another login ends it.
    @Test func aHoldStaysWhileTheStatusCanStillBeItsLogin() {
        let issue = UsageIssue("Limited.", retryAt: .reference(120))
        let limited = AccountUsage(
            id: "a", name: "A", observedAt: .reference(-60), issue: issue, owner: alice)
        #expect(limited.rateLimitHold(admittedBy: .unknown, now: .reference()) == issue)
        #expect(limited.rateLimitHold(admittedBy: .signedIn(alice), now: .reference()) == issue)
        #expect(limited.rateLimitHold(admittedBy: .signedIn(bob), now: .reference()) == nil)
        #expect(limited.rateLimitHold(admittedBy: .signedOut, now: .reference()) == nil)
        #expect(limited.rateLimitHold(admittedBy: .unknown, now: .reference(120)) == nil)

        var noOwner = limited
        noOwner.owner = nil
        #expect(noOwner.rateLimitHold(admittedBy: .unknown, now: .reference()) == nil)
    }

    /// An account without an observation still holds, so a first 429 is not sent again.
    @Test func anUnavailableAccountHoldsToo() {
        let issue = UsageIssue("Limited.", retryAt: .reference(120))
        let unavailable = AccountUsage.unavailable(
            id: "a", name: "A", issue: issue, attemptedAt: .reference(), owner: alice)
        #expect(unavailable.rateLimitHold(for: alice, now: .reference(60)) == issue)
    }
}

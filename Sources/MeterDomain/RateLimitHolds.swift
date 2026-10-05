import Foundation

/// The rate-limit holds that a provider keeps in memory: at most one for each login
/// (``RateLimitHold``).
///
/// A 429 for one login never replaces the hold of another login. So after a 429 for login A,
/// then one for login B, A still waits when it signs in again before its retry time. A value
/// type: the provider keeps it behind its own lock.
public struct RateLimitHolds: Hashable, Sendable {
    private var retryTimes: [AccountOwner: Date] = [:]

    public init() {}

    /// Keeps `hold`, and drops every hold that ended at `now` (``RateLimitHold/holds(_:now:)``).
    /// When the login already has a hold that has not ended, the later retry time stays.
    public mutating func record(_ hold: RateLimitHold, now: Date) {
        retryTimes = retryTimes.filter { owner, retryAt in
            RateLimitHold(owner: owner, retryAt: retryAt).holds(owner, now: now)
        }
        if let kept = retryTimes[hold.owner], kept >= hold.retryAt { return }
        if hold.holds(hold.owner, now: now) {
            retryTimes[hold.owner] = hold.retryAt
        }
    }

    /// When `owner` may send again, or nil when no hold stops its requests at `now`.
    public func retryAt(for owner: AccountOwner, now: Date) -> Date? {
        guard let retryAt = retryTimes[owner],
            RateLimitHold(owner: owner, retryAt: retryAt).holds(owner, now: now)
        else { return nil }
        return retryAt
    }
}

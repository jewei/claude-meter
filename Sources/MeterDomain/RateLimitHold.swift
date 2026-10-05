import Foundation

/// A pause after HTTP 429 for one login: the one rule that Codex, Cursor, and Grok share.
///
/// - The pause lasts until the server's retry time, at most ``maximum`` after the 429
///   (``retryAt(delay:now:)``).
/// - It holds only the requests of the login that got the 429. Another login sends at once.
/// - A retry time more than ``maximum`` after now holds nothing (``holds(_:now:)``). This rule
///   never makes such a time, so the clock moved back or an older version saved it. That
///   hold ends, also after a restart that loads it from the reading archive.
///
/// Without a retry time nothing is held. Claude has its own gate, because one Claude limit
/// covers every account and the Settings check.
public struct RateLimitHold: Hashable, Sendable {
    /// The longest pause: 1 hour, so a wrong `Retry-After` cannot stop requests for longer.
    public static let maximum: TimeInterval = 60 * 60

    /// The login that got the 429.
    public let owner: AccountOwner
    public let retryAt: Date

    public init(owner: AccountOwner, retryAt: Date) {
        self.owner = owner
        self.retryAt = retryAt
    }

    /// The retry time to keep after HTTP 429 at `now`: `delay` seconds later, at most
    /// ``maximum``. Nil when the server sent no delay in the future.
    public static func retryAt(delay: TimeInterval?, now: Date) -> Date? {
        guard let delay, delay > 0 else { return nil }
        return now.addingTimeInterval(min(delay, maximum))
    }

    /// Whether this hold stops a request for `owner` at `now`.
    public func holds(_ owner: AccountOwner, now: Date) -> Bool {
        let remaining = retryAt.timeIntervalSince(now)
        return owner == self.owner && remaining > 0 && remaining <= Self.maximum
    }
}

extension AccountUsage {
    /// The HTTP 429 issue of this account that still holds the requests of `owner` at `now`,
    /// or nil (``RateLimitHold``). A refresh that finds one sends nothing and keeps the account
    /// with this issue, so the card's countdown is true.
    public func rateLimitHold(for owner: AccountOwner, now: Date) -> UsageIssue? {
        guard let issue, let retryAt = issue.retryAt, let held = self.owner,
            RateLimitHold(owner: held, retryAt: retryAt).holds(owner, now: now)
        else { return nil }
        return issue
    }

    /// The HTTP 429 issue that still holds this account's own login at `now`, while `status`
    /// can still be that login (``OwnerStatus/admits(_:)``), or nil.
    ///
    /// A refresh that sends nothing for the held login, such as one with an expired token or a
    /// login that cannot be read now, keeps this issue instead of its own. So the hold and the
    /// card's countdown stay true. A sign-out or another login ends the hold for this account.
    public func rateLimitHold(admittedBy status: OwnerStatus, now: Date) -> UsageIssue? {
        guard let owner, status.admits(owner) else { return nil }
        return rateLimitHold(for: owner, now: now)
    }
}

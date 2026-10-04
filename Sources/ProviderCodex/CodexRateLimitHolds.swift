import Foundation
import MeterDomain
import MeterPlatform

/// The rate-limit holds of every Codex home (``RateLimitHold``).
///
/// A 429 of the usage request is in the account's issue. A 429 of the reset-credit details
/// request has no issue, because the usage request of that refresh succeeded, so it lives here
/// in memory, and a restart ends it. A login that got HTTP 429 in one home is held in every
/// home, because the limit belongs to the login.
final class CodexRateLimitHolds: Sendable {
    private let detailsHolds = Locked<[RateLimitHold]>([])

    /// The holds that a fetch at `now` must respect: those in the issues of every previous
    /// account, and those kept in memory.
    func current(previous: ProviderUsage?, now: Date) -> [RateLimitHold] {
        let issued = (previous?.accounts ?? []).compactMap { account -> RateLimitHold? in
            guard let owner = account.owner,
                let retryAt = account.rateLimitHold(for: owner, now: now)?.retryAt
            else { return nil }
            return RateLimitHold(owner: owner, retryAt: retryAt)
        }
        return issued + detailsHolds.value.filter { $0.holds($0.owner, now: now) }
    }

    /// Keeps a hold for each login whose reset-credit details request got HTTP 429, and drops
    /// the holds that ended.
    func record(_ attempts: [CodexAttempt], now: Date) {
        let started = attempts.compactMap { attempt -> RateLimitHold? in
            guard case .observed(let quota, let owner) = attempt.outcome.kind,
                let retryAt = quota.resetDetailsRetryAt
            else { return nil }
            return RateLimitHold(owner: owner, retryAt: retryAt)
        }
        detailsHolds.withLock { holds in
            holds = (holds + started).filter { $0.holds($0.owner, now: now) }
        }
    }
}

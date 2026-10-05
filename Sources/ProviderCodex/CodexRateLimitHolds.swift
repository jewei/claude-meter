import Foundation
import MeterDomain
import MeterPlatform

/// The rate-limit holds of every Codex home (``RateLimitHold``).
///
/// A login that got HTTP 429 in one home is held in every home, because the limit belongs to
/// the login. A 429 of the usage request is in the account's issue once the refresh ends. A
/// 429 of the reset-credit details request has no issue, because the usage request of that
/// refresh succeeded. So each 429 is also kept here, in memory, as soon as Codex answers: a
/// refresh that is cancelled after the 429, or a home that does not finish by the fetch
/// deadline, still holds the login. A restart before the next refresh ends a hold that only
/// memory keeps. A refresh during the hold puts the 429 issue on the account, and that hold
/// then survives a restart like a usage-request hold.
final class CodexRateLimitHolds: Sendable {
    private let held = Locked<[RateLimitHold]>([])

    /// The holds that a fetch at `now` must respect: those in the issues of every previous
    /// account, and those kept in memory.
    func current(previous: ProviderUsage?, now: Date) -> [RateLimitHold] {
        let issued = (previous?.accounts ?? []).compactMap { account -> RateLimitHold? in
            guard let owner = account.owner,
                let retryAt = account.rateLimitHold(for: owner, now: now)?.retryAt
            else { return nil }
            return RateLimitHold(owner: owner, retryAt: retryAt)
        }
        return issued + held.value.filter { $0.holds($0.owner, now: now) }
    }

    /// Keeps `hold`, the pause after HTTP 429 for the login that sent the request, and drops
    /// the holds that ended.
    func record(_ hold: RateLimitHold, now: Date) {
        held.withLock { holds in
            holds = (holds.filter { $0 != hold } + [hold]).filter { $0.holds($0.owner, now: now) }
        }
    }
}

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
/// deadline, still holds the login, and so does a home that starts later in the same fetch.
/// A restart before the next refresh ends a hold that only memory keeps. A refresh during the
/// hold puts the 429 issue on the account, and that hold then survives a restart like a
/// usage-request hold.
final class CodexRateLimitHolds: Sendable {
    private let memory = Locked(RateLimitHolds())

    /// The holds in the issues of the accounts of `previous` at `now`. A fetch reads them
    /// once, at its start, because the issues change only when the fetch ends.
    static func issued(by previous: ProviderUsage?, now: Date) -> RateLimitHolds {
        var holds = RateLimitHolds()
        for account in previous?.accounts ?? [] {
            guard let owner = account.owner,
                let retryAt = account.rateLimitHold(for: owner, now: now)?.retryAt
            else { continue }
            holds.record(RateLimitHold(owner: owner, retryAt: retryAt), now: now)
        }
        return holds
    }

    /// When `owner` may send again, or nil when no hold stops it at `now`: the later retry
    /// time of `issued` and of memory. Memory is read at each call, so a home that starts after
    /// a 429 for its login in the same fetch waits too.
    func retryAt(for owner: AccountOwner, issued: RateLimitHolds, now: Date) -> Date? {
        [issued.retryAt(for: owner, now: now), memory.value.retryAt(for: owner, now: now)]
            .compactMap { $0 }.max()
    }

    /// Keeps `hold`, the pause after HTTP 429 for the login that sent the request.
    func record(_ hold: RateLimitHold, now: Date) {
        memory.withLock { $0.record(hold, now: now) }
    }
}

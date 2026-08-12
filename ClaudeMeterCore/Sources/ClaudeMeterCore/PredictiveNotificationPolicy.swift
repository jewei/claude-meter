import Foundation

public struct PredictiveNotificationTrigger: Equatable, Sendable {
    public let accountID: String
    public let scope: String
    public let resetAt: Date
    public let secondsUntilDepleted: TimeInterval

    public init(
        accountID: String,
        scope: String,
        resetAt: Date,
        secondsUntilDepleted: TimeInterval
    ) {
        self.accountID = accountID
        self.scope = scope
        self.resetAt = resetAt
        self.secondsUntilDepleted = secondsUntilDepleted
    }

    public init(
        accountID: String,
        scope: LimitWindowScope,
        resetAt: Date,
        secondsUntilDepleted: TimeInterval
    ) {
        self.init(
            accountID: accountID, scope: scope.rawValue, resetAt: resetAt,
            secondsUntilDepleted: secondsUntilDepleted)
    }

    public var typedScope: LimitWindowScope? { LimitWindowScope(rawValue: scope) }

    /// Persisted dedup key. The reset epoch is bucketed (see
    /// `PredictiveNotificationTracker.resetBucket`) so jittery `resets_at` values
    /// for the same window — e.g. the statusline and OAuth tiers rounding
    /// differently — can't re-fire the same forecast under a fresh key.
    public var dedupKey: String {
        let encodedAccount = Base64URL.encode(Data(accountID.utf8))
        let epoch = PredictiveNotificationTracker.bucketedEpoch(resetAt)
        return "\(NotificationPolicy.dedupKeyPrefix)predictive.\(encodedAccount).\(scope).\(epoch)"
    }
}

/// Confirms a projected depletion on two consecutive fresh polls before alerting.
/// State is in memory only; successful deliveries use the persisted dedup key.
public struct PredictiveNotificationTracker: Sendable {
    private struct ObservationKey: Hashable, Sendable {
        let accountID: String
        let scope: LimitWindowScope
        let resetEpoch: Int
    }

    /// Keys that qualified on the immediately-previous fresh poll. A key present
    /// here that qualifies again *is* the "two consecutive polls" confirmation.
    private var previousQualifiers: Set<ObservationKey> = []

    /// Sticky active-account identity. OAuth-tier snapshots carry `accounts == nil`
    /// even for multi-account users, so without this a statusline↔OAuth tier flip
    /// would rename the account (real key ↔ "claude") every poll — wiping streaks
    /// or double-firing the same window under two dedup keys.
    private var lastActiveAccountID: String?

    public init() {}

    public mutating func resetQualificationStreak() {
        previousQualifiers.removeAll()
    }

    /// Backward-compatible spelling. This intentionally retains sticky account identity.
    public mutating func reset() {
        resetQualificationStreak()
    }

    /// Width of the reset-time bucket. The same window's `resets_at` arrives with
    /// slightly different rounding depending on which tier reported it, so raw
    /// timestamps would look like distinct cycles — wiping the two-poll streak, or
    /// re-firing an already-delivered forecast under a fresh dedup key.
    static let resetBucket: TimeInterval = 5 * 60

    /// Rounds a reset timestamp to the nearest `resetBucket` so jittery values from
    /// the same cycle compare equal.
    static func bucketedReset(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let secs = (date.timeIntervalSinceReferenceDate / resetBucket).rounded() * resetBucket
        return Date(timeIntervalSinceReferenceDate: secs)
    }

    static func bucketedEpoch(_ date: Date) -> Int {
        Int((bucketedReset(date) ?? date).timeIntervalSince1970)
    }

    public mutating func observe(
        snapshot: ClaudeUsageSnapshot,
        thresholds: UsageThresholds = .default,
        isFresh: Bool = true,
        now: Date = Date()
    ) -> [PredictiveNotificationTrigger] {
        guard isFresh else {
            resetQualificationStreak()
            return []
        }
        let accountID: String
        if let active = snapshot.accounts?.first(where: { $0.isActive })?.id {
            accountID = active
            lastActiveAccountID = active
        } else {
            accountID = lastActiveAccountID ?? "claude"
        }
        var qualifying: [(ObservationKey, PredictiveNotificationTrigger)] = []
        for candidate in snapshot.limits.bindingWindows {
            let window = candidate.window.resolved(asOf: now)
            guard thresholds.severity(for: window.percentUsed) == .normal,
                let resetAt = window.resetsAt,
                resetAt > now,
                case .runsOut(let seconds) = window.runsOutEstimate(
                    kind: candidate.scope.kind, asOf: now),
                seconds > 0
            else { continue }

            let proposedKey = ObservationKey(
                accountID: accountID,
                scope: candidate.scope,
                resetEpoch: Self.bucketedEpoch(resetAt)
            )
            // Carry forward the first observation's canonical cycle identity when
            // two sources put the same reset on opposite sides of a rounding boundary.
            let key =
                previousQualifiers.first(where: {
                    $0.accountID == proposedKey.accountID && $0.scope == proposedKey.scope
                        && abs($0.resetEpoch - proposedKey.resetEpoch) <= Int(Self.resetBucket)
                }) ?? proposedKey
            let canonicalReset = Date(timeIntervalSince1970: TimeInterval(key.resetEpoch))
            qualifying.append(
                (
                    key,
                    PredictiveNotificationTrigger(
                        accountID: accountID,
                        scope: candidate.scope,
                        resetAt: canonicalReset,
                        secondsUntilDepleted: seconds
                    )
                ))
        }

        let triggers = qualifying.filter { previousQualifiers.contains($0.0) }.map(\.1)
        previousQualifiers = Set(qualifying.map(\.0))
        return triggers
    }
}

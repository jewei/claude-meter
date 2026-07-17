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

    /// Persisted dedup key. The reset epoch is bucketed (5 min, matching
    /// `UsageHistoryStore.resetBucket`) so jittery `resets_at` values for the same
    /// window — e.g. the statusline and OAuth tiers rounding differently — can't
    /// re-fire the same forecast under a fresh key.
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
        let scope: String
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

    public mutating func reset() {
        previousQualifiers.removeAll()
    }

    static func bucketedEpoch(_ date: Date) -> Int {
        Int((UsageHistoryStore.bucketedReset(date) ?? date).timeIntervalSince1970)
    }

    public mutating func observe(
        snapshot: ClaudeUsageSnapshot,
        thresholds: UsageThresholds = .default,
        now: Date = Date()
    ) -> [PredictiveNotificationTrigger] {
        let accountID: String
        if let active = snapshot.accounts?.first(where: { $0.isActive })?.id {
            accountID = active
            lastActiveAccountID = active
        } else {
            accountID = lastActiveAccountID ?? "claude"
        }
        let candidates: [(scope: String, window: LimitWindow, kind: LimitWindowKind)] =
            [
                ("session", snapshot.limits.currentSession, .session),
                ("weekly", snapshot.limits.currentWeekAllModels, .weekly),
            ] + (snapshot.limits.currentWeekOpus.map { [("weeklyOpus", $0, .weekly)] } ?? [])

        var qualifying: [(ObservationKey, PredictiveNotificationTrigger)] = []
        for candidate in candidates {
            let window = candidate.window.resolved(asOf: now)
            guard thresholds.severity(for: window.percentUsed) == .normal,
                let resetAt = window.resetsAt,
                resetAt > now,
                case .runsOut(let seconds) = window.runsOutEstimate(
                    kind: candidate.kind, asOf: now),
                seconds > 0
            else { continue }

            let key = ObservationKey(
                accountID: accountID,
                scope: candidate.scope,
                resetEpoch: Self.bucketedEpoch(resetAt)
            )
            qualifying.append(
                (
                    key,
                    PredictiveNotificationTrigger(
                        accountID: accountID,
                        scope: candidate.scope,
                        resetAt: resetAt,
                        secondsUntilDepleted: seconds
                    )
                ))
        }

        let triggers = qualifying.filter { previousQualifiers.contains($0.0) }.map(\.1)
        previousQualifiers = Set(qualifying.map(\.0))
        return triggers
    }
}

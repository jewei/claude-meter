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
}

/// Confirms a projected depletion on two consecutive fresh polls before alerting.
/// State is in memory only; successful deliveries use the persisted dedup key.
public struct PredictiveNotificationTracker: Sendable {
    private struct ObservationKey: Hashable, Sendable {
        let accountID: String
        let scope: String
        let resetEpoch: Int
    }

    private var streaks: [ObservationKey: Int] = [:]

    public init() {}

    public mutating func reset() {
        streaks.removeAll()
    }

    public mutating func observe(
        snapshot: ClaudeUsageSnapshot,
        thresholds: UsageThresholds = .default,
        now: Date = Date()
    ) -> [PredictiveNotificationTrigger] {
        let accountID = snapshot.accounts?.first(where: { $0.isActive })?.id ?? "claude"
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
                resetEpoch: Int(resetAt.timeIntervalSince1970)
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

        let currentKeys = Set(qualifying.map(\.0))
        streaks = streaks.filter { currentKeys.contains($0.key) }

        var triggers: [PredictiveNotificationTrigger] = []
        for (key, trigger) in qualifying {
            let next = min(2, (streaks[key] ?? 0) + 1)
            streaks[key] = next
            if next >= 2 { triggers.append(trigger) }
        }
        return triggers
    }
}

public enum PredictiveNotificationPolicy {
    public static func dedupKey(
        accountID: String,
        scope: String,
        resetAt: Date
    ) -> String {
        let encodedAccount = Data(accountID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return
            "\(NotificationPolicy.dedupKeyPrefix)predictive.\(encodedAccount).\(scope).\(Int(resetAt.timeIntervalSince1970))"
    }
}

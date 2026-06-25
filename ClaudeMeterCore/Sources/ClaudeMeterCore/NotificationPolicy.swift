import Foundation

public struct NotificationTrigger: Equatable, Sendable {
    public let scope: String
    public let level: String
    public let resetAt: Date

    public init(scope: String, level: String, resetAt: Date) {
        self.scope = scope
        self.level = level
        self.resetAt = resetAt
    }
}

/// Pure threshold-crossing logic for local usage notifications.
public enum NotificationPolicy {
    public static let dedupKeyPrefix = "com.claudemeter.notif."

    /// Returns notification triggers for scopes whose severity escalated since `previous`.
    public static func triggers(
        snapshot: ClaudeUsageSnapshot,
        previous: ClaudeUsageSnapshot?,
        thresholds: UsageThresholds = .default,
        now: Date = Date()
    ) -> [NotificationTrigger] {
        [
            evaluate(
                scope: "session",
                current: snapshot.limits.currentSession,
                previous: previous?.limits.currentSession,
                thresholds: thresholds,
                now: now
            ),
            evaluate(
                scope: "weekly",
                current: snapshot.limits.currentWeekAllModels,
                previous: previous?.limits.currentWeekAllModels,
                thresholds: thresholds,
                now: now
            ),
            evaluate(
                scope: "weeklyOpus",
                current: snapshot.limits.currentWeekOpus ?? LimitWindow(),
                previous: previous?.limits.currentWeekOpus ?? LimitWindow(),
                thresholds: thresholds,
                now: now
            ),
        ].flatMap { $0 }
    }

    public static func dedupKey(scope: String, level: String, resetAt: Date) -> String {
        "\(dedupKeyPrefix)\(scope).\(level).\(Int(resetAt.timeIntervalSince1970))"
    }

    /// Removes dedup keys whose reset epoch is in the past.
    public static func expiredDedupKeys(in keys: [String], now: Date = Date()) -> [String] {
        let nowEpoch = Int(now.timeIntervalSince1970)
        return keys.filter { key in
            guard key.hasPrefix(dedupKeyPrefix),
                let epochToken = key.split(separator: ".").last,
                let epoch = Int(epochToken)
            else {
                return false
            }
            return epoch < nowEpoch
        }
    }

    // MARK: - Private

    private static func evaluate(
        scope: String,
        current rawCurrent: LimitWindow,
        previous rawPrevious: LimitWindow?,
        thresholds: UsageThresholds,
        now: Date
    ) -> [NotificationTrigger] {
        // Rolling windows past their reset read as 0% — resolve for the current
        // state, but keep the *raw* previous reading for recovery detection.
        let current = rawCurrent.resolved(asOf: now)
        let previousSeverity = thresholds.severity(for: rawPrevious?.resolved(asOf: now).percentUsed)
        let currentSeverity = thresholds.severity(for: current.percentUsed)

        let escalatedToCritical = isCritical(currentSeverity) && !isCritical(previousSeverity)
        let escalatedToWarning =
            currentSeverity == .warning
            && (previousSeverity == .normal || previousSeverity == .unknown)

        if escalatedToCritical || escalatedToWarning {
            let resetAt: Date
            if let parsed = current.resetsAt {
                guard parsed > now else { return [] }
                resetAt = parsed
            } else {
                resetAt = fallbackResetAnchor(now: now)
            }
            let level = escalatedToCritical ? "critical" : "warning"
            return [NotificationTrigger(scope: scope, level: level, resetAt: resetAt)]
        }

        // Recovery ("refueled"): a window the user was previously over — by its
        // *raw* reading, so a reset/refill still counts — is back to normal.
        let rawPreviousSeverity = thresholds.severity(for: rawPrevious?.percentUsed)
        if currentSeverity == .normal && isElevated(rawPreviousSeverity) {
            let resetAt = current.resetsAt ?? fallbackResetAnchor(now: now)
            return [NotificationTrigger(scope: scope, level: "recovered", resetAt: resetAt)]
        }

        return []
    }

    private static func fallbackResetAnchor(now: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86400)
    }

    private static func isCritical(_ severity: UsageSeverity) -> Bool {
        severity == .critical || severity == .overLimit
    }

    private static func isElevated(_ severity: UsageSeverity) -> Bool {
        severity == .warning || severity == .critical || severity == .overLimit
    }
}

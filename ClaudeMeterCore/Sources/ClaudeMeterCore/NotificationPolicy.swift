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
                current: snapshot.limits.currentSession.resolved(asOf: now),
                previous: previous?.limits.currentSession.resolved(asOf: now),
                thresholds: thresholds,
                now: now
            ),
            evaluate(
                scope: "weekly",
                current: snapshot.limits.currentWeekAllModels.resolved(asOf: now),
                previous: previous?.limits.currentWeekAllModels.resolved(asOf: now),
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
                  let epoch = Int(epochToken) else {
                return false
            }
            return epoch < nowEpoch
        }
    }

    // MARK: - Private

    private static func evaluate(
        scope: String,
        current: LimitWindow,
        previous: LimitWindow?,
        thresholds: UsageThresholds,
        now: Date
    ) -> [NotificationTrigger] {
        let previousSeverity = thresholds.severity(for: previous?.percentUsed)
        let currentSeverity = thresholds.severity(for: current.percentUsed)

        let escalatedToCritical = isCritical(currentSeverity) && !isCritical(previousSeverity)
        let escalatedToWarning = currentSeverity == .warning
            && (previousSeverity == .normal || previousSeverity == .unknown)

        guard escalatedToCritical || escalatedToWarning else { return [] }

        let resetAt: Date
        if let parsed = current.resetsAt {
            guard parsed > now else { return [] }
            resetAt = parsed
        } else {
            resetAt = fallbackResetAnchor(now: now)
        }

        var result: [NotificationTrigger] = []

        if escalatedToCritical {
            result.append(NotificationTrigger(scope: scope, level: "critical", resetAt: resetAt))
        } else if escalatedToWarning {
            result.append(NotificationTrigger(scope: scope, level: "warning", resetAt: resetAt))
        }

        return result
    }

    private static func fallbackResetAnchor(now: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86400)
    }

    private static func isCritical(_ severity: UsageSeverity) -> Bool {
        severity == .critical || severity == .overLimit
    }
}

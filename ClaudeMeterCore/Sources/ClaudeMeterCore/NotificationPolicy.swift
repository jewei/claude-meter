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
        now: Date = Date()
    ) -> [NotificationTrigger] {
        [
            evaluate(
                scope: "session",
                current: snapshot.limits.currentSession,
                previous: previous?.limits.currentSession,
                now: now
            ),
            evaluate(
                scope: "weekly",
                current: snapshot.limits.currentWeekAllModels,
                previous: previous?.limits.currentWeekAllModels,
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
        now: Date
    ) -> [NotificationTrigger] {
        guard let resetAt = current.resetsAt, resetAt > now else { return [] }

        let previousSeverity = UsageSeverity.from(percent: previous?.percentUsed)
        let currentSeverity = UsageSeverity.from(percent: current.percentUsed)

        var result: [NotificationTrigger] = []

        if isCritical(currentSeverity), !isCritical(previousSeverity) {
            result.append(NotificationTrigger(scope: scope, level: "critical", resetAt: resetAt))
        } else if currentSeverity == .warning,
                  (previousSeverity == .normal || previousSeverity == .unknown) {
            result.append(NotificationTrigger(scope: scope, level: "warning", resetAt: resetAt))
        }

        return result
    }

    private static func isCritical(_ severity: UsageSeverity) -> Bool {
        severity == .critical || severity == .overLimit
    }
}

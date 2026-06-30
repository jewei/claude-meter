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
    ///
    /// `recoveryBaseline` supplies the previous reading used *only* for "refueled"
    /// recovery detection; it defaults to `previous`. The split lets the caller suppress
    /// escalation on the first poll of a session (pass `previous: nil` to avoid a stale
    /// cross-window crossing) while still detecting a recovery against the persisted
    /// snapshot — so a window that reset while the app was quit still fires "refueled".
    public static func triggers(
        snapshot: ClaudeUsageSnapshot,
        previous: ClaudeUsageSnapshot?,
        recoveryBaseline: ClaudeUsageSnapshot?? = nil,
        thresholds: UsageThresholds = .default,
        now: Date = Date()
    ) -> [NotificationTrigger] {
        // Top-level limits mirror the *active* account, so diff against THAT account's
        // own previous entry (matched by id) — an active-account switch otherwise
        // compares two unrelated accounts. When the active account wasn't observed
        // last poll (new account, or a switch out of single-account history) there's
        // no baseline, so its current state is surfaced once. Single-account snapshots
        // (no `accounts`) never switch, so the top-level previous is the same account.
        let resolvedRecovery: ClaudeUsageSnapshot? = recoveryBaseline ?? previous
        func limits(of snap: ClaudeUsageSnapshot?) -> LimitInfo? {
            if let activeId = snapshot.accounts?.first(where: { $0.isActive })?.id {
                return snap?.accounts?.first(where: { $0.id == activeId })?.limits
            }
            return snap?.limits
        }
        let prevLimits = limits(of: previous)
        let recoveryLimits = limits(of: resolvedRecovery)

        var out: [NotificationTrigger] = []
        out += evaluate(
            scope: "session",
            current: snapshot.limits.currentSession,
            previous: prevLimits?.currentSession,
            recoveryPrevious: recoveryLimits?.currentSession,
            thresholds: thresholds, now: now)
        out += evaluate(
            scope: "weekly",
            current: snapshot.limits.currentWeekAllModels,
            previous: prevLimits?.currentWeekAllModels,
            recoveryPrevious: recoveryLimits?.currentWeekAllModels,
            thresholds: thresholds, now: now)
        // Only diff Opus when *both* snapshots carry it — otherwise the first OAuth
        // enrichment (previous nil, current already 85%+) looks like a fresh crossing.
        if let curOpus = snapshot.limits.currentWeekOpus, let prevOpus = prevLimits?.currentWeekOpus
        {
            out += evaluate(
                scope: "weeklyOpus", current: curOpus, previous: prevOpus,
                recoveryPrevious: recoveryLimits?.currentWeekOpus,
                thresholds: thresholds, now: now)
        }
        return out
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
        recoveryPrevious rawRecoveryPrevious: LimitWindow?,
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
        // *raw* reading, so a reset/refill still counts — is back to normal. Usage is
        // monotonic within a window, so in practice the only way down is a reset; we
        // don't special-case "gradual" drops. A stray low reading would yield at most
        // one "refueled" (de-duped per reset window), which is harmless.
        let rawRecoverySeverity = thresholds.severity(for: rawRecoveryPrevious?.percentUsed)
        if currentSeverity == .normal && isElevated(rawRecoverySeverity) {
            // Anchor the dedup key on the window the user recovered *from* (its raw
            // reset), so distinct cycles don't collapse onto one day-anchor key.
            let resetAt =
                rawRecoveryPrevious?.resetsAt ?? current.resetsAt ?? fallbackResetAnchor(now: now)
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

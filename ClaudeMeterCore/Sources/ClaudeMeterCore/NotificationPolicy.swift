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

    public init(scope: LimitWindowScope, level: NotificationLevel, resetAt: Date) {
        self.init(scope: scope.rawValue, level: level.rawValue, resetAt: resetAt)
    }

    public var typedScope: LimitWindowScope? { LimitWindowScope(rawValue: scope) }
    public var typedLevel: NotificationLevel? { NotificationLevel(rawValue: level) }
}

public enum NotificationLevel: String, Codable, Equatable, Sendable, CaseIterable {
    case warning
    case critical
    case recovered
}

public struct MainMeterNotificationBaselines: Sendable {
    public let escalation: MainMeterReading?
    public let recovery: MainMeterReading?

    public init(escalation: MainMeterReading?, recovery: MainMeterReading?) {
        self.escalation = escalation
        self.recovery = recovery
    }
}

public struct NotificationBaselines: Sendable {
    public let escalation: ClaudeUsageSnapshot?
    public let recovery: ClaudeUsageSnapshot?

    public init(escalation: ClaudeUsageSnapshot?, recovery: ClaudeUsageSnapshot?) {
        self.escalation = escalation
        self.recovery = recovery
    }
}

/// Pure threshold-crossing logic for local usage notifications.
public enum NotificationPolicy {
    public static let dedupKeyPrefix = "com.claudemeter.notif."

    public static func mainMeterBaselines(
        reading: MainMeterReading,
        previous: MainMeterReading?,
        notificationIdentity: String?,
        allowsPersistedRecovery: Bool
    ) -> MainMeterNotificationBaselines {
        let sameReadingIdentity = previous?.stableIdentity == reading.stableIdentity
        let continuesInSession = notificationIdentity == reading.stableIdentity
        return MainMeterNotificationBaselines(
            escalation: sameReadingIdentity && continuesInSession ? previous : nil,
            recovery: sameReadingIdentity
                && (continuesInSession || allowsPersistedRecovery) ? previous : nil)
    }

    /// Provider-neutral threshold policy for the selected main meter. Baselines from
    /// another provider or account are ignored so switching the meter never creates a
    /// synthetic crossing or recovery.
    public static func triggers(
        reading: MainMeterReading,
        previous: MainMeterReading?,
        recoveryBaseline: MainMeterReading?? = nil,
        thresholds: UsageThresholds = .default,
        now: Date = Date()
    ) -> [NotificationTrigger] {
        let recovery: MainMeterReading? = recoveryBaseline ?? previous
        return triggers(
            reading: reading,
            baselines: MainMeterNotificationBaselines(
                escalation: previous, recovery: recovery),
            thresholds: thresholds,
            now: now)
    }

    public static func triggers(
        reading: MainMeterReading,
        baselines: MainMeterNotificationBaselines,
        thresholds: UsageThresholds = .default,
        now: Date = Date()
    ) -> [NotificationTrigger] {
        let previous = baselines.escalation.flatMap {
            $0.stableIdentity == reading.stableIdentity ? $0 : nil
        }
        let recovery = baselines.recovery.flatMap {
            $0.stableIdentity == reading.stableIdentity ? $0 : nil
        }
        var out: [NotificationTrigger] = []
        out += evaluate(
            scope: .session,
            current: reading.limits.currentSession,
            previous: previous?.limits.currentSession,
            recoveryPrevious: recovery?.limits.currentSession,
            allowMissingBaselineEscalation: false,
            thresholds: thresholds,
            now: now)
        out += evaluate(
            scope: .weekly,
            current: reading.limits.currentWeekAllModels,
            previous: previous?.limits.currentWeekAllModels,
            recoveryPrevious: recovery?.limits.currentWeekAllModels,
            allowMissingBaselineEscalation: false,
            thresholds: thresholds,
            now: now)
        if let currentOpus = reading.limits.currentWeekOpus,
            let previousOpus = previous?.limits.currentWeekOpus
        {
            out += evaluate(
                scope: .weeklyOpus,
                current: currentOpus,
                previous: previousOpus,
                recoveryPrevious: recovery?.limits.currentWeekOpus,
                allowMissingBaselineEscalation: false,
                thresholds: thresholds,
                now: now)
        }
        return out
    }

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
        let resolvedRecovery: ClaudeUsageSnapshot? = recoveryBaseline ?? previous
        return triggers(
            snapshot: snapshot,
            baselines: NotificationBaselines(
                escalation: previous, recovery: resolvedRecovery),
            thresholds: thresholds,
            now: now)
    }

    /// Typed-baseline variant for new callers. Keeping escalation and recovery
    /// separate avoids nested-optional call sites such as `.some(nil)`.
    public static func triggers(
        snapshot: ClaudeUsageSnapshot,
        baselines: NotificationBaselines,
        thresholds: UsageThresholds = .default,
        now: Date = Date()
    ) -> [NotificationTrigger] {
        // Top-level limits mirror the *active* account, so diff against THAT account's
        // own previous entry (matched by id) — an active-account switch otherwise
        // compares two unrelated accounts. When the active account wasn't observed
        // last poll (new account, or a switch out of single-account history) there's
        // no baseline, so its current state is surfaced once. Single-account snapshots
        // (no `accounts`) never switch, so the top-level previous is the same account.
        let prevLimits = snapshot.limitsForActiveAccount(in: baselines.escalation)
        let recoveryLimits = snapshot.limitsForActiveAccount(in: baselines.recovery)

        var out: [NotificationTrigger] = []
        out += evaluate(
            scope: .session,
            current: snapshot.limits.currentSession,
            previous: prevLimits?.currentSession,
            recoveryPrevious: recoveryLimits?.currentSession,
            allowMissingBaselineEscalation: baselines.escalation != nil,
            thresholds: thresholds, now: now)
        out += evaluate(
            scope: .weekly,
            current: snapshot.limits.currentWeekAllModels,
            previous: prevLimits?.currentWeekAllModels,
            recoveryPrevious: recoveryLimits?.currentWeekAllModels,
            allowMissingBaselineEscalation: baselines.escalation != nil,
            thresholds: thresholds, now: now)
        // Only diff Opus when *both* snapshots carry it — otherwise the first OAuth
        // enrichment (previous nil, current already 85%+) looks like a fresh crossing.
        if let curOpus = snapshot.limits.currentWeekOpus, let prevOpus = prevLimits?.currentWeekOpus
        {
            out += evaluate(
                scope: .weeklyOpus, current: curOpus, previous: prevOpus,
                recoveryPrevious: recoveryLimits?.currentWeekOpus,
                allowMissingBaselineEscalation: false,
                thresholds: thresholds, now: now)
        }
        return out
    }

    public static func dedupKey(scope: String, level: String, resetAt: Date) -> String {
        let epoch = resetAt.boundedUnixEpochSecond.map(String.init) ?? "invalid"
        return "\(dedupKeyPrefix)\(scope).\(level).\(epoch)"
    }

    public static func dedupKey(
        scope: LimitWindowScope, level: NotificationLevel, resetAt: Date
    ) -> String {
        dedupKey(scope: scope.rawValue, level: level.rawValue, resetAt: resetAt)
    }

    /// Removes dedup keys whose reset epoch is in the past.
    public static func expiredDedupKeys(in keys: [String], now: Date = Date()) -> [String] {
        guard let nowEpoch = now.boundedUnixEpochSecond else { return [] }
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
        scope: LimitWindowScope,
        current rawCurrent: LimitWindow,
        previous rawPrevious: LimitWindow?,
        recoveryPrevious rawRecoveryPrevious: LimitWindow?,
        allowMissingBaselineEscalation: Bool,
        thresholds: UsageThresholds,
        now: Date
    ) -> [NotificationTrigger] {
        // Rolling windows past their reset read as 0% — resolve for the current
        // state, but keep the *raw* previous reading for recovery detection.
        let current = rawCurrent.resolved(asOf: now)
        let previousSeverity = thresholds.severity(
            for: rawPrevious?.resolved(asOf: now).percentUsed)
        let currentSeverity = thresholds.severity(for: current.percentUsed)

        // No previous reading means no observed crossing. This suppresses stale
        // launch-time alerts while still allowing the separate recovery baseline.
        let hasEscalationBaseline = rawPrevious != nil || allowMissingBaselineEscalation
        let escalatedToCritical =
            hasEscalationBaseline && isCritical(currentSeverity) && !isCritical(previousSeverity)
        let escalatedToWarning =
            hasEscalationBaseline && currentSeverity == .warning
            && (previousSeverity == .normal || previousSeverity == .unknown)

        if escalatedToCritical || escalatedToWarning {
            let resetAt: Date
            if let parsed = current.resetsAt {
                guard parsed > now, parsed.boundedUnixEpochSecond != nil else { return [] }
                resetAt = parsed
            } else {
                resetAt = fallbackResetAnchor(now: now)
            }
            let level: NotificationLevel = escalatedToCritical ? .critical : .warning
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
            let candidate =
                rawRecoveryPrevious?.resetsAt ?? current.resetsAt ?? fallbackResetAnchor(now: now)
            let resetAt =
                candidate.boundedUnixEpochSecond == nil ? fallbackResetAnchor(now: now) : candidate
            return [NotificationTrigger(scope: scope, level: .recovered, resetAt: resetAt)]
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

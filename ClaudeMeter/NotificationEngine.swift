import UserNotifications
import ClaudeMeterCore

/// Posts local notifications when session or weekly usage crosses severity thresholds.
///
/// Deduplication: one notification per (scope, level, reset-window). The fired state is
/// stored in UserDefaults, keyed by the window's `resetsAt` epoch seconds, so notifications
/// are not repeated across app relaunches within the same reset window. Expired keys are
/// pruned when the reset time passes.
actor NotificationEngine {
    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert])
    }

    // MARK: - Processing

    func process(
        snapshot: ClaudeUsageSnapshot,
        previous: ClaudeUsageSnapshot?,
        isStale: Bool
    ) async {
        guard !isStale, isEnabled(), await isAuthorized() else { return }

        pruneExpiredKeys()
        let thresholds = Self.thresholds(from: defaults)
        let pending = NotificationPolicy.triggers(
            snapshot: snapshot,
            previous: previous,
            thresholds: thresholds
        )

        for trigger in pending {
            deliver(trigger: trigger, snapshot: snapshot)
        }
    }

    // MARK: - Delivery

    private func deliver(trigger: NotificationTrigger, snapshot: ClaudeUsageSnapshot) {
        let window = trigger.scope == "session"
            ? snapshot.limits.currentSession
            : snapshot.limits.currentWeekAllModels
        let label = trigger.scope == "session" ? "Session" : "Weekly (all models)"
        let pct = window.displayPercent ?? "—"
        let key = NotificationPolicy.dedupKey(
            scope: trigger.scope,
            level: trigger.level,
            resetAt: trigger.resetAt
        )

        if trigger.level == "critical" {
            guard !hasFired(key: key) else { return }
            post(
                id: key,
                title: "\(label) limit nearly reached — \(pct)",
                body: "Resets \(resetDescription(trigger.resetAt))."
            )
            markFired(key: key)
        } else if trigger.level == "warning" {
            let criticalKey = NotificationPolicy.dedupKey(
                scope: trigger.scope,
                level: "critical",
                resetAt: trigger.resetAt
            )
            guard !hasFired(key: key), !hasFired(key: criticalKey) else { return }
            post(
                id: key,
                title: "\(label) usage high — \(pct)",
                body: "Resets \(resetDescription(trigger.resetAt))."
            )
            markFired(key: key)
        }
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { _ in }
    }

    // MARK: - Deduplication

    private func hasFired(key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    private func markFired(key: String) {
        defaults.set(true, forKey: key)
    }

    private func pruneExpiredKeys() {
        let allKeys = defaults.dictionaryRepresentation().keys.map { String($0) }
        for key in NotificationPolicy.expiredDedupKeys(in: allKeys) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Settings

    private func isEnabled() -> Bool {
        guard defaults.object(forKey: "enableNotifications") != nil else { return true }
        return defaults.bool(forKey: "enableNotifications")
    }

    private static func thresholds(from defaults: UserDefaults) -> UsageThresholds {
        let warning = defaults.double(forKey: "warningThresholdPercent").positive ?? 80
        let critical = defaults.double(forKey: "criticalThresholdPercent").positive ?? 95
        return UsageThresholds(
            warning: warning,
            critical: max(critical, warning + 1)
        )
    }

    // MARK: - Helpers

    private func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let shortDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .short
        return f
    }()

    private func resetDescription(_ date: Date) -> String {
        let interval = date.timeIntervalSince(Date())
        if interval < 3600 {
            let mins = max(1, Int(interval / 60))
            return "in \(mins)m"
        }
        if Calendar.current.isDateInToday(date) {
            return "at \(Self.shortTimeFormatter.string(from: date))"
        }
        return Self.shortDateTimeFormatter.string(from: date)
    }
}

private extension Double {
    var positive: Double? { self > 0 ? self : nil }
}

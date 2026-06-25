import ClaudeMeterCore
import UserNotifications

/// Posts local notifications when session or weekly usage crosses severity thresholds.
///
/// Deduplication: one notification per (scope, level, reset-window). The fired state is
/// stored in UserDefaults under a dedicated key array, keyed by the window's `resetsAt`
/// epoch seconds, so notifications are not repeated across app relaunches within the
/// same reset window. Expired keys are pruned when the reset time passes.
actor NotificationEngine {
    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults

    private static let firedKeysStorageKey = "com.claudemeter.notif.firedKeys"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert])
    }

    /// Notifies the user that a new app version is available (gentle Sparkle reminder path).
    func postUpdateAvailable(version: String) async {
        guard isEnabled(), await isAuthorized() else { return }
        _ = await post(
            id: "com.claudemeter.update.\(version)",
            title: "Claude Meter update available",
            body: "Version \(version) is ready. Open the menu bar popover to install."
        )
    }

    // MARK: - Processing

    func process(
        snapshot: ClaudeUsageSnapshot,
        previous: ClaudeUsageSnapshot?,
        isStale: Bool
    ) async {
        guard !isStale, isEnabled(), await isAuthorized() else { return }

        pruneExpiredKeys()
        let thresholds = AppGroupConfig.currentThresholds(defaults: defaults)
        let pending = NotificationPolicy.triggers(
            snapshot: snapshot,
            previous: previous,
            thresholds: thresholds
        )

        for trigger in pending {
            await deliver(trigger: trigger, snapshot: snapshot)
        }
    }

    // MARK: - Delivery

    private func deliver(trigger: NotificationTrigger, snapshot: ClaudeUsageSnapshot) async {
        let window: LimitWindow
        switch trigger.scope {
        case "session": window = snapshot.limits.currentSession
        case "weeklyOpus": window = snapshot.limits.currentWeekOpus ?? LimitWindow()
        default: window = snapshot.limits.currentWeekAllModels
        }
        // The whole app speaks "energy left", so notifications do too.
        let left = leftText(window)
        let energy = energyName(for: trigger.scope)
        let key = NotificationPolicy.dedupKey(
            scope: trigger.scope,
            level: trigger.level,
            resetAt: trigger.resetAt
        )

        if trigger.level == "recovered" {
            guard !hasFired(key: key) else { return }
            let delivered = await post(
                id: key,
                title: "You're refueled! 🎉",
                body: "Your \(energy) is back to \(left). Go get 'em."
            )
            if delivered { markFired(key: key) }
            return
        }

        let refuel = "\(trigger.scope == "session" ? "refills" : "resets") \(resetDescription(trigger.resetAt))"

        if trigger.level == "critical" {
            guard !hasFired(key: key) else { return }
            let delivered = await post(
                id: key,
                title: "Almost tapped out 🪫",
                body: "Your \(energy) is at \(left) — \(refuel). Easy now."
            )
            if delivered { markFired(key: key) }
        } else if trigger.level == "warning" {
            let criticalKey = NotificationPolicy.dedupKey(
                scope: trigger.scope,
                level: "critical",
                resetAt: trigger.resetAt
            )
            guard !hasFired(key: key), !hasFired(key: criticalKey) else { return }
            let delivered = await post(
                id: key,
                title: "Running low ⚡",
                body: "Your \(energy) is at \(left) — \(refuel). Maybe touch grass? 🌱"
            )
            if delivered { markFired(key: key) }
        }
    }

    /// Energy-left ("9%") for a window, the inverse of usage.
    private func leftText(_ window: LimitWindow) -> String {
        guard let left = window.percentLeft(asOf: Date()) else { return "—" }
        return "\(Int(left.rounded()))%"
    }

    private func energyName(for scope: String) -> String {
        switch scope {
        case "session": return "5-hour energy"
        case "weeklyOpus": return "weekly Opus fuel"
        default: return "weekly fuel"
        }
    }

    private func post(id: String, title: String, body: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    // MARK: - Deduplication

    private func firedKeys() -> [String] {
        defaults.stringArray(forKey: Self.firedKeysStorageKey) ?? []
    }

    private func hasFired(key: String) -> Bool {
        firedKeys().contains(key)
    }

    private func markFired(key: String) {
        var keys = firedKeys()
        guard !keys.contains(key) else { return }
        keys.append(key)
        defaults.set(keys, forKey: Self.firedKeysStorageKey)
    }

    private func pruneExpiredKeys() {
        let expired = NotificationPolicy.expiredDedupKeys(in: firedKeys())
        guard !expired.isEmpty else { return }
        let expiredSet = Set(expired)
        let remaining = firedKeys().filter { !expiredSet.contains($0) }
        defaults.set(remaining, forKey: Self.firedKeysStorageKey)
    }

    // MARK: - Settings

    private func isEnabled() -> Bool {
        guard defaults.object(forKey: "enableNotifications") != nil else { return true }
        return defaults.bool(forKey: "enableNotifications")
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

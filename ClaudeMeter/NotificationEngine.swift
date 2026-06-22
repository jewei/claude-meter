import UserNotifications
import ClaudeMeterCore

/// Posts local notifications when session or weekly usage crosses severity thresholds.
///
/// Deduplication: one notification per (scope, level, reset-window). The fired state is
/// stored in UserDefaults, keyed by the window's `resetsAt` epoch seconds, so notifications
/// are not repeated across app relaunches within the same reset window.
actor NotificationEngine {
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert])
    }

    // MARK: - Processing

    func process(snapshot: ClaudeUsageSnapshot) async {
        guard await isAuthorized() else { return }
        evaluate(scope: "session",  label: "Session",            window: snapshot.limits.currentSession)
        evaluate(scope: "weekly",   label: "Weekly (all models)", window: snapshot.limits.currentWeekAllModels)
    }

    // MARK: - Threshold evaluation

    private func evaluate(scope: String, label: String, window: LimitWindow) {
        guard let percent = window.percentUsed,
              let resetAt = window.resetsAt,
              resetAt > Date() else { return }

        let severity = UsageSeverity.from(percent: percent)
        let pct = window.displayPercent ?? "\(Int(min(100, max(0, percent))))%"

        switch severity {
        case .critical, .overLimit:
            guard !hasFired(scope: scope, level: "critical", resetAt: resetAt) else { return }
            post(
                id: dedupKey(scope: scope, level: "critical", resetAt: resetAt),
                title: "\(label) limit nearly reached — \(pct)",
                body: "Resets \(resetDescription(resetAt))."
            )
            markFired(scope: scope, level: "critical", resetAt: resetAt)

        case .warning:
            // Suppress warning if critical already fired for this window
            guard !hasFired(scope: scope, level: "warning",  resetAt: resetAt),
                  !hasFired(scope: scope, level: "critical", resetAt: resetAt) else { return }
            post(
                id: dedupKey(scope: scope, level: "warning", resetAt: resetAt),
                title: "\(label) usage high — \(pct)",
                body: "Resets \(resetDescription(resetAt))."
            )
            markFired(scope: scope, level: "warning", resetAt: resetAt)

        default:
            break
        }
    }

    // MARK: - Posting

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { _ in }
    }

    // MARK: - Deduplication

    private func dedupKey(scope: String, level: String, resetAt: Date) -> String {
        "com.claudemeter.notif.\(scope).\(level).\(Int(resetAt.timeIntervalSince1970))"
    }

    private func hasFired(scope: String, level: String, resetAt: Date) -> Bool {
        defaults.bool(forKey: dedupKey(scope: scope, level: level, resetAt: resetAt))
    }

    private func markFired(scope: String, level: String, resetAt: Date) {
        defaults.set(true, forKey: dedupKey(scope: scope, level: level, resetAt: resetAt))
    }

    // MARK: - Helpers

    private func isAuthorized() async -> Bool {
        await center.notificationSettings().authorizationStatus == .authorized
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

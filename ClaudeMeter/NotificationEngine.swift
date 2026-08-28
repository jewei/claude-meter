import ClaudeMeterCore
import ClaudeMeterProviders
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
    private var predictiveTracker = PredictiveNotificationTracker()

    private static let firedKeysStorageKey = "com.claudemeter.notif.firedKeys"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined else { return }
        // Request sound too, so attention notifications can play the user's sound.
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
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

    /// Posts a "Claude needs you" notification for an attention event. Caller has
    /// already applied focus-suppression; this only gates on the master toggle +
    /// authorization. Each event is consumed once, so no extra dedup is needed.
    func postAttention(event: SessionEvent, accountLabel: String) async {
        // Gated only by authorization — attention has its own Settings toggles and is
        // independent of the quota-notification master switch (`isEnabled()`).
        guard await isAuthorized() else { return }
        let project = event.projectName ?? "a session"
        let title: String
        let body: String
        switch event.kind {
        case .stop:
            title = "Claude finished ✅"
            body = "\(project) · \(accountLabel) — your turn"
        case .notification:
            title = "Claude needs you"
            let detail = (event.message?.isEmpty == false) ? event.message! : "Waiting for input"
            body = "\(detail) · \(project) · \(accountLabel)"
        case .stopFailure:
            title = "Claude blocked 🚫"
            let detail: String
            switch event.errorType {
            case "rate_limit": detail = "Rate limit hit"
            case "billing_error": detail = "Billing issue"
            default: detail = "Limit hit"
            }
            body = "\(detail) · \(project) · \(accountLabel)"
        case .other:
            return
        }
        let id =
            "com.claudemeter.attention.\(event.accountKey).\(event.sessionId ?? "?").\(event.kind.rawValue).\(Int(event.capturedAt.timeIntervalSince1970))"
        // Default sound → macOS plays the user's chosen per-app notification sound
        // and respects Focus/Do-Not-Disturb. (Quota notifications stay silent.)
        let userInfo =
            event.terminalRoute.map {
                AttentionNotificationRoute(route: $0, cwd: event.cwd).userInfo
            } ?? [:]
        _ = await post(
            id: id, title: title, body: body, sound: .default, userInfo: userInfo)
    }

    // MARK: - Processing

    func process(
        reading: MainMeterReading,
        previous: MainMeterReading?,
        recoveryBaseline: MainMeterReading?,
        isStale: Bool
    ) async {
        guard !isStale, isEnabled(), await isAuthorized() else {
            predictiveTracker.reset()
            return
        }

        let now = Date()
        pruneExpiredKeys()
        let thresholds = AppGroupConfig.currentThresholds(defaults: defaults)
        let pending = NotificationPolicy.triggers(
            reading: reading,
            previous: previous,
            recoveryBaseline: recoveryBaseline,
            thresholds: thresholds,
            now: now
        )

        for trigger in pending {
            await deliver(trigger: trigger, reading: reading, now: now)
        }

        if defaults.bool(forKey: AppSettings.predictiveNotificationsEnabledKey) {
            let predictive = predictiveTracker.observe(
                snapshot: predictiveSnapshot(for: reading),
                thresholds: thresholds,
                now: now
            )
            for trigger in predictive {
                await deliverPredictive(trigger: trigger, reading: reading)
            }
        } else {
            predictiveTracker.reset()
        }
    }

    // MARK: - Delivery

    private func deliver(trigger: NotificationTrigger, reading: MainMeterReading, now: Date) async {
        guard let scope = trigger.typedScope, let level = trigger.typedLevel else { return }
        let window = reading.limits.window(for: scope) ?? LimitWindow()
        let left = leftText(window, now: now)
        let energy = energyName(for: scope, reading: reading)
        let key = notificationKey(
            reading: reading, scope: scope, level: level, resetAt: trigger.resetAt)
        let legacyKey = legacyClaudeKey(
            reading: reading, scope: scope, level: level, resetAt: trigger.resetAt)
        let account = reading.accountLabel

        if level == .recovered {
            guard !hasFired(key: key, legacyKey: legacyKey) else { return }
            let delivered = await post(
                id: key,
                title: "You're refueled! 🎉",
                body: "\(account)'s \(energy) is back to \(left). Go get 'em."
            )
            if delivered { markFired(key: key) }
            return
        }

        let refuel =
            "\(scope == .session ? "refills" : "resets") \(resetDescription(trigger.resetAt))"

        if level == .critical {
            guard !hasFired(key: key, legacyKey: legacyKey) else { return }
            let delivered = await post(
                id: key,
                title: "Almost tapped out 🪫",
                body: "\(account)'s \(energy) is at \(left) — \(refuel). Easy now."
            )
            if delivered { markFired(key: key) }
        } else if level == .warning {
            let criticalKey = notificationKey(
                reading: reading, scope: scope, level: .critical, resetAt: trigger.resetAt)
            let legacyCriticalKey = legacyClaudeKey(
                reading: reading, scope: scope, level: .critical, resetAt: trigger.resetAt)
            guard !hasFired(key: key, legacyKey: legacyKey),
                !hasFired(key: criticalKey, legacyKey: legacyCriticalKey)
            else { return }
            let delivered = await post(
                id: key,
                title: "Running low ⚡",
                body: "\(account)'s \(energy) is at \(left) — \(refuel). Maybe touch grass? 🌱"
            )
            if delivered { markFired(key: key) }
        }
    }

    private func deliverPredictive(
        trigger: PredictiveNotificationTrigger,
        reading: MainMeterReading
    ) async {
        guard let scope = trigger.typedScope else { return }
        let key = trigger.dedupKey
        let legacyKey: String? =
            reading.provider == .claude
            ? PredictiveNotificationTrigger(
                accountID: reading.accountID,
                scope: trigger.scope,
                resetAt: trigger.resetAt,
                secondsUntilDepleted: trigger.secondsUntilDepleted
            ).dedupKey
            : nil
        guard !hasFired(key: key, legacyKey: legacyKey) else { return }
        let energy = energyName(for: scope, reading: reading)
        let estimate =
            RunsOutPhrase.spoken(.runsOut(seconds: trigger.secondsUntilDepleted))?
            .lowercased() ?? "may run out soon"
        let delivered = await post(
            id: key,
            title: "Running hot ⚡",
            body:
                "At this pace, \(reading.accountLabel)'s \(energy) \(estimate), before it refills."
        )
        if delivered { markFired(key: key) }
    }

    /// Breaks the predictive tracker's "consecutive fresh polls" chain when a poll
    /// throws, times out, or comes back fatal — those polls never reach `process`,
    /// and without this the streak would survive arbitrary outage gaps.
    func pollFailed() {
        predictiveTracker.reset()
    }

    /// Energy-left ("9%") for a window, the inverse of usage.
    private func leftText(_ window: LimitWindow, now: Date) -> String {
        guard let left = window.percentLeft(asOf: now) else { return "—" }
        return "\(Int(left.rounded()))%"
    }

    private func energyName(
        for scope: LimitWindowScope,
        reading: MainMeterReading
    ) -> String {
        switch scope {
        case .session: return "\(reading.sessionLabel) energy"
        case .weeklyOpus: return "weekly Opus fuel"
        case .weekly: return "\(reading.weeklyLabel) fuel"
        }
    }

    private func notificationKey(
        reading: MainMeterReading,
        scope: LimitWindowScope,
        level: NotificationLevel,
        resetAt: Date
    ) -> String {
        NotificationPolicy.dedupKey(
            scope: "\(notificationNamespace(reading)).\(scope.rawValue)",
            level: level.rawValue,
            resetAt: resetAt)
    }

    private func legacyClaudeKey(
        reading: MainMeterReading,
        scope: LimitWindowScope,
        level: NotificationLevel,
        resetAt: Date
    ) -> String? {
        guard reading.provider == .claude else { return nil }
        return NotificationPolicy.dedupKey(scope: scope, level: level, resetAt: resetAt)
    }

    private func notificationNamespace(_ reading: MainMeterReading) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in reading.stableIdentity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(reading.provider.rawValue).\(String(hash, radix: 16))"
    }

    private func predictiveSnapshot(for reading: MainMeterReading) -> ClaudeUsageSnapshot {
        let identity = notificationNamespace(reading)
        let thresholds = AppGroupConfig.currentThresholds(defaults: defaults)
        let severity = reading.severity(thresholds: thresholds)
        return ClaudeUsageSnapshot(
            parserVersion: "main-meter-1",
            createdAt: reading.observedAt,
            lastSuccessfulPollAt: reading.observedAt,
            source: SourceInfo(
                cliPath: reading.provider.rawValue,
                command: "main-meter"),
            limits: reading.limits,
            state: SnapshotState(status: .ok, severity: severity),
            accounts: [
                AccountUsage(
                    id: identity,
                    label: reading.accountLabel,
                    limits: reading.limits,
                    lastSuccessfulPollAt: reading.observedAt,
                    severity: severity,
                    isActive: true)
            ])
    }

    private func post(
        id: String, title: String, body: String, sound: UNNotificationSound? = nil,
        userInfo: [AnyHashable: Any] = [:]
    ) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Deduplication

    private func firedKeys() -> [String] {
        defaults.stringArray(forKey: Self.firedKeysStorageKey) ?? []
    }

    private func hasFired(key: String) -> Bool {
        firedKeys().contains(key)
    }

    private func hasFired(key: String, legacyKey: String?) -> Bool {
        hasFired(key: key) || legacyKey.map { hasFired(key: $0) } == true
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

    private func resetDescription(_ date: Date) -> String {
        ResetPhrase.spoken(until: date, asOf: Date()) ?? "soon"
    }
}

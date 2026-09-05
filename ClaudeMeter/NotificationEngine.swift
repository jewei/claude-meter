import ClaudeMeterCore
import ClaudeMeterProviders
import Foundation
import UserNotifications

enum NotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case provisional
    case unavailable
}

/// Immutable value passed across the notification-delivery test seam. `userInfo`
/// contains only property-list values created by `AttentionNotificationRoute`.
struct NotificationDeliveryRequest: @unchecked Sendable {
    let identifier: String
    let title: String
    let body: String
    let playsDefaultSound: Bool
    let userInfo: [AnyHashable: Any]
}

protocol NotificationDelivery: Sendable {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws
    func add(_ request: NotificationDeliveryRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String]) async
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async
}

private final class SystemNotificationDelivery: NotificationDelivery, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationState() async -> NotificationAuthorizationState {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .provisional: .provisional
        case .denied, .ephemeral: .unavailable
        @unknown default: .unavailable
        }
    }

    func requestAuthorization() async throws {
        // Request sound too, so attention notifications can play the user's sound.
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: NotificationDeliveryRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = request.playsDefaultSound ? .default : nil
        content.userInfo = request.userInfo
        try await center.add(
            UNNotificationRequest(
                identifier: request.identifier,
                content: content,
                trigger: nil))
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// A synchronous revision gate lets main-actor setting changes invalidate an
/// observation before an actor task can resume from `add`. The commit closure runs
/// under the same lock as invalidation, so revision validation and fired-state
/// persistence are one operation.
private final class NotificationObservationRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func invalidate() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    func performIfCurrent(_ expected: Int, operation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == expected else { return false }
        operation()
        return true
    }
}

/// Posts local notifications when session or weekly usage crosses severity thresholds.
///
/// Deduplication: one notification per (scope, level, reset-window). The fired state is
/// stored in UserDefaults under a dedicated key array, keyed by the window's `resetsAt`
/// epoch seconds, so notifications are not repeated across app relaunches within the
/// same reset window. Expired keys are pruned when the reset time passes.
actor NotificationEngine {
    private struct QuotaDelivery: Hashable {
        let key: String
        let revision: Int
    }

    private let delivery: any NotificationDelivery
    private let defaults: UserDefaults
    private var quotaDeliveriesInFlight: Set<QuotaDelivery> = []
    private var predictiveTracker = PredictiveNotificationTracker()
    private var predictiveTrackerRevision = 0
    /// Changes when a failed poll or meter setting invalidates an observation
    /// that can be suspended in Notification Center calls.
    private let observationRevision = NotificationObservationRevision()
    /// Changes only with the attention lifecycle. Quota poll failures must not
    /// retract an unrelated "Claude needs you" alert.
    private let attentionRevision = NotificationObservationRevision()
    /// Changes only with notification settings. Quota poll failures must not
    /// retract an unrelated update alert.
    private let updateRevision = NotificationObservationRevision()

    private static let firedKeysStorageKey = "com.claudemeter.notif.firedKeys"

    init(
        defaults: UserDefaults = .standard,
        delivery: (any NotificationDelivery)? = nil
    ) {
        self.defaults = defaults
        self.delivery = delivery ?? SystemNotificationDelivery()
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        guard await delivery.authorizationState() == .notDetermined else { return }
        try? await delivery.requestAuthorization()
    }

    /// Notifies the user that a new app version is available (gentle Sparkle reminder path).
    func postUpdateAvailable(version: String) async {
        let revision = updateRevision.current()
        guard isEnabled(), await isAuthorized(),
            updateRevision.current() == revision,
            !Task.isCancelled
        else { return }
        let id = "com.claudemeter.update.\(version)"
        let delivered = await post(
            id: id,
            title: "Claude Meter update available",
            body: "Version \(version) is ready. Open the menu bar popover to install."
        )
        if let delivered {
            await retractIfInvalid(
                id: delivered, expectedRevision: revision, revisionGate: updateRevision)
        }
    }

    /// Posts a "Claude needs you" notification for an attention event. Caller has
    /// already applied focus-suppression; this only gates on the master toggle +
    /// authorization. Each event is consumed once, so no extra dedup is needed.
    nonisolated func attentionLease() -> Int {
        attentionRevision.current()
    }

    func postAttention(
        event: SessionEvent,
        accountLabel: String,
        expectedRevision revision: Int
    ) async {
        guard attentionRevision.current() == revision, !Task.isCancelled else { return }
        // Gated only by authorization — attention has its own Settings toggles and is
        // independent of the quota-notification master switch (`isEnabled()`).
        guard await isAuthorized(), attentionRevision.current() == revision,
            !Task.isCancelled
        else { return }
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
        let capturedEpoch = event.capturedAt.boundedUnixEpochSecond.map(String.init) ?? "invalid"
        let id =
            "com.claudemeter.attention.\(event.accountKey).\(event.sessionId ?? "?").\(event.kind.rawValue).\(capturedEpoch)"
        // Default sound → macOS plays the user's chosen per-app notification sound
        // and respects Focus/Do-Not-Disturb. (Quota notifications stay silent.)
        let userInfo =
            event.terminalRoute.map {
                AttentionNotificationRoute(route: $0, cwd: event.cwd).userInfo
            } ?? [:]
        let delivered = await post(
            id: id, title: title, body: body, sound: .default, userInfo: userInfo)
        if let delivered {
            await retractIfInvalid(
                id: delivered, expectedRevision: revision, revisionGate: attentionRevision)
        }
    }

    // MARK: - Processing

    /// Captures the quota-observation revision before a caller enqueues actor work.
    /// A setting or selected-meter change can then invalidate queued work before
    /// this actor starts it.
    nonisolated func quotaLease() -> Int {
        observationRevision.current()
    }

    func process(
        reading: MainMeterReading,
        previous: MainMeterReading?,
        recoveryBaseline: MainMeterReading?,
        isStale: Bool,
        expectedRevision revision: Int
    ) async {
        guard observationRevision.current() == revision, !Task.isCancelled else { return }
        if predictiveTrackerRevision != revision {
            predictiveTracker.reset()
            predictiveTrackerRevision = revision
        }
        guard !isStale, isEnabled(), await isAuthorized()
        else {
            predictiveTracker.reset()
            return
        }
        guard observationRevision.current() == revision, !Task.isCancelled else { return }

        let now = Date()
        pruneExpiredKeys()
        let thresholds = AppGroupConfig.currentThresholds(shared: nil, defaults: defaults)
        let pending = NotificationPolicy.triggers(
            reading: reading,
            previous: previous,
            recoveryBaseline: recoveryBaseline,
            thresholds: thresholds,
            now: now
        )

        for trigger in pending {
            guard observationRevision.current() == revision, !Task.isCancelled else { return }
            await deliver(
                trigger: trigger,
                reading: reading,
                now: now,
                expectedRevision: revision)
        }

        guard observationRevision.current() == revision, !Task.isCancelled else { return }
        if defaults.bool(forKey: AppSettings.predictiveNotificationsEnabledKey) {
            let predictive = predictiveTracker.observe(
                snapshot: predictiveSnapshot(for: reading),
                thresholds: thresholds,
                now: now
            )
            for trigger in predictive {
                guard observationRevision.current() == revision, !Task.isCancelled else { return }
                await deliverPredictive(
                    trigger: trigger,
                    reading: reading,
                    expectedRevision: revision)
            }
        } else {
            predictiveTracker.reset()
        }
    }

    // MARK: - Delivery

    private func deliver(
        trigger: NotificationTrigger,
        reading: MainMeterReading,
        now: Date,
        expectedRevision: Int
    ) async {
        guard observationRevision.current() == expectedRevision, !Task.isCancelled else { return }
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
            await postQuota(
                key: key,
                title: "You're refueled! 🎉",
                body: "\(account)'s \(energy) is back to \(left). Go get 'em.",
                expectedRevision: expectedRevision
            )
            return
        }

        let refuel =
            "\(scope == .session ? "refills" : "resets") \(resetDescription(trigger.resetAt))"

        if level == .critical {
            guard !hasFired(key: key, legacyKey: legacyKey) else { return }
            await postQuota(
                key: key,
                title: "Almost tapped out 🪫",
                body: "\(account)'s \(energy) is at \(left) — \(refuel). Easy now.",
                expectedRevision: expectedRevision
            )
        } else if level == .warning {
            let criticalKey = notificationKey(
                reading: reading, scope: scope, level: .critical, resetAt: trigger.resetAt)
            let legacyCriticalKey = legacyClaudeKey(
                reading: reading, scope: scope, level: .critical, resetAt: trigger.resetAt)
            guard !hasFired(key: key, legacyKey: legacyKey),
                !hasFired(key: criticalKey, legacyKey: legacyCriticalKey)
            else { return }
            await postQuota(
                key: key,
                title: "Running low ⚡",
                body: "\(account)'s \(energy) is at \(left) — \(refuel). Maybe touch grass? 🌱",
                expectedRevision: expectedRevision
            )
        }
    }

    private func deliverPredictive(
        trigger: PredictiveNotificationTrigger,
        reading: MainMeterReading,
        expectedRevision: Int
    ) async {
        guard observationRevision.current() == expectedRevision, !Task.isCancelled else { return }
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
        await postQuota(
            key: key,
            title: "Running hot ⚡",
            body:
                "At this pace, \(reading.accountLabel)'s \(energy) \(estimate), before it refills.",
            expectedRevision: expectedRevision
        )
    }

    /// Breaks the predictive tracker's "consecutive fresh polls" chain when a poll
    /// throws, times out, or comes back fatal — those polls never reach `process`,
    /// and without this the streak would survive arbitrary outage gaps.
    nonisolated func pollFailed() {
        observationRevision.invalidate()
    }

    /// Invalidates quota and update alerts that are suspended in Notification
    /// Center calls after a notification setting changes.
    nonisolated func notificationSettingsChanged() {
        observationRevision.invalidate()
        updateRevision.invalidate()
    }

    /// Invalidates an attention alert that is suspended in authorization or add.
    nonisolated func attentionSettingsChanged() {
        attentionRevision.invalidate()
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
        let thresholds = AppGroupConfig.currentThresholds(shared: nil, defaults: defaults)
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
    ) async -> String? {
        // Retraction belongs to one delivery attempt. Reusing the dedup key here
        // would let a late invalidated add remove a newer valid notification.
        let requestID = "\(id).\(UUID().uuidString)"
        let request = NotificationDeliveryRequest(
            identifier: requestID,
            title: title,
            body: body,
            playsDefaultSound: sound != nil,
            userInfo: userInfo)
        do {
            try await delivery.add(request)
            return requestID
        } catch {
            return nil
        }
    }

    private func postQuota(
        key: String, title: String, body: String, expectedRevision: Int
    ) async {
        let attempt = QuotaDelivery(key: key, revision: expectedRevision)
        guard quotaDeliveriesInFlight.insert(attempt).inserted else { return }
        defer { quotaDeliveriesInFlight.remove(attempt) }
        guard let requestID = await post(id: key, title: title, body: body) else { return }
        await commitFiredOrRetract(
            key: key, requestID: requestID, expectedRevision: expectedRevision)
    }

    private func commitFiredOrRetract(
        key: String, requestID: String, expectedRevision: Int
    ) async {
        let committed =
            !Task.isCancelled
            && observationRevision.performIfCurrent(expectedRevision) {
                markFired(key: key)
            }
        guard !committed else { return }
        await delivery.removePendingRequests(withIdentifiers: [requestID])
        await delivery.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    private func retractIfInvalid(
        id: String,
        expectedRevision: Int,
        revisionGate: NotificationObservationRevision
    ) async {
        let remainsValid =
            !Task.isCancelled
            && revisionGate.performIfCurrent(expectedRevision) {}
        guard !remainsValid else { return }
        await delivery.removePendingRequests(withIdentifiers: [id])
        await delivery.removeDeliveredNotifications(withIdentifiers: [id])
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
        let state = await delivery.authorizationState()
        return state == .authorized || state == .provisional
    }

    private func resetDescription(_ date: Date) -> String {
        ResetPhrase.spoken(until: date, asOf: Date()) ?? "soon"
    }
}

import Foundation
import MeterDomain
import MeterPlatform
import Observation

/// Runs ``AlertEvaluator`` and posts what it owes.
///
/// Evaluations run after store changes and alert or threshold changes, merged per main-actor
/// turn, and only while macOS allows notifications, so no alert is used up before permission.
/// The new state is saved before posting, so a second change during a slow post cannot send
/// the same alert. A post that fails is logged and not retried: a lost alert is better than a
/// duplicate.
@MainActor @Observable
public final class AlertCenter {
    public nonisolated static let authorizationLimit: Duration = .seconds(5)
    public nonisolated static let postLimit: Duration = .seconds(5)
    /// The permission prompt waits for the person, so it gets a long limit of its own.
    public nonisolated static let requestLimit: Duration = .seconds(600)

    /// What macOS allows. Nil until the first read.
    public private(set) var authorization: NotificationAuthorization?

    @ObservationIgnored private let poster: (any NotificationPosting)?
    @ObservationIgnored private let context: @MainActor () -> PresentationContext
    @ObservationIgnored private let limits: Limits
    @ObservationIgnored private let log = Log(.app)
    @ObservationIgnored private(set) var state = AlertEvaluator.State()
    @ObservationIgnored private var pendingEvaluation: Task<Void, Never>?
    @ObservationIgnored private var permissionRequest: Task<Void, Never>?
    /// Counts permission reads, so an older read that answers late cannot overwrite a newer
    /// one.
    @ObservationIgnored private var authorizationReads = 0
    /// A permission read that an evaluation without permission started.
    @ObservationIgnored private var skippedEvaluationRead: Task<Void, Never>?
    /// How many evaluations ran or were skipped for lack of permission, for tests.
    @ObservationIgnored private(set) var evaluationCount = 0
    /// The latest delivery, for tests.
    @ObservationIgnored private(set) var latestDelivery: Task<Void, Never>?

    struct Limits {
        var authorization = AlertCenter.authorizationLimit
        var post = AlertCenter.postLimit
        var request = AlertCenter.requestLimit
    }

    /// - Parameters:
    ///   - poster: Nil in previews: nothing is posted.
    ///   - context: The presentation context at the current time.
    init(
        poster: (any NotificationPosting)?, limits: Limits = Limits(),
        context: @escaping @MainActor () -> PresentationContext
    ) {
        self.poster = poster
        self.limits = limits
        self.context = context
    }

    private var enabledKinds: Set<Alert.Kind> { context().settings.alerts.enabledKinds }

    /// Reads the permission, and asks for it when an alert is on and the app never asked.
    func start() async {
        await refreshAuthorization()
        if !enabledKinds.isEmpty { requestPermissionIfNeeded() }
    }

    /// Reads the permission again, so a change in System Settings applies without a relaunch.
    /// The app calls it when Settings opens and when the app becomes active.
    public func refreshAuthorization() async {
        guard let poster else { return }
        authorizationReads += 1
        let read = authorizationReads
        do {
            let value = try await withDeadline(limits.authorization) {
                await poster.authorization()
            }
            guard read == authorizationReads else { return }
            let wasAuthorized = authorization == .authorized
            authorization = value
            if value == .authorized, !wasAuthorized { scheduleEvaluation() }
        } catch {
            log.warning("Reading the notification permission failed: \(error)")
        }
    }

    /// Applies a change of the alert switches or the thresholds.
    func settingsDidChange(from old: Settings, to new: Settings) {
        state.forgetDroppedAccounts(new)
        let before = old.alerts.enabledKinds
        let after = new.alerts.enabledKinds
        for kind in after.subtracting(before) {
            state.activate(kind, providers: new.enabledProviders)
        }
        for kind in before.subtracting(after) {
            state.deactivate(kind)
        }
        if !after.subtracting(before).isEmpty { requestPermissionIfNeeded() }
        if before != after || old.appearance.thresholds != new.appearance.thresholds {
            scheduleEvaluation()
        }
    }

    /// Evaluates after each change of the readings, for as long as the store lives.
    func observe(_ usage: UsageStore) {
        withObservationTracking {
            _ = usage.readings
            _ = usage.restored
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe(usage)
                self?.scheduleEvaluation()
            }
        }
    }

    /// Evaluates once at the end of this main-actor turn, however many changes it has.
    func scheduleEvaluation() {
        guard pendingEvaluation == nil else { return }
        pendingEvaluation = Task { [weak self] in
            guard let self else { return }
            pendingEvaluation = nil
            evaluate()
        }
    }

    private func requestPermissionIfNeeded() {
        guard let poster, authorization == .notDetermined || authorization == nil,
            permissionRequest == nil
        else { return }
        let limit = limits.request
        permissionRequest = Task { [weak self] in
            _ = try? await withDeadline(limit) { await poster.requestAuthorization() }
            guard let self else { return }
            permissionRequest = nil
            await refreshAuthorization()
        }
    }

    private func evaluate() {
        evaluationCount += 1
        guard let poster else { return }
        guard authorization == .authorized else {
            // The popover does not make the app active, so a permission granted later in
            // System Settings is noticed here. A grant schedules the next evaluation.
            if skippedEvaluationRead == nil {
                skippedEvaluationRead = Task { [weak self] in
                    await self?.refreshAuthorization()
                    self?.skippedEvaluationRead = nil
                }
            }
            return
        }
        let (alerts, newState) = AlertEvaluator.evaluate(
            context(), enabledKinds: enabledKinds, previous: state)
        state = newState
        guard !alerts.isEmpty else { return }
        let limit = limits.post
        let log = log
        let previous = latestDelivery
        latestDelivery = Task { [weak self] in
            // Deliveries keep their order.
            await previous?.value
            for alert in alerts {
                // A post can wait up to its limit. An alert whose switch was turned off in the
                // meantime is dropped.
                guard self?.enabledKinds.contains(alert.kind) == true else { continue }
                let notification = LocalNotification(
                    id: alert.notificationID, title: alert.title, body: alert.body)
                let posted = (try? await withDeadline(limit) { await poster.post(notification) })
                if posted != true {
                    log.warning(
                        "macOS did not accept the \(alert.kind.rawValue) alert for "
                            + "\(alert.key.provider.displayName). It is not sent again.")
                }
            }
        }
    }
}

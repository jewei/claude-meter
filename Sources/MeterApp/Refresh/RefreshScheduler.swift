import Foundation
import MeterDomain
import MeterPlatform

/// What the scheduler may do. Built from settings by the composition root.
public struct RefreshConfiguration: Equatable, Sendable {
    /// Onboarding is complete and the user has not paused updates.
    public var isActive: Bool
    public var enabledProviders: Set<ProviderID>

    public init(isActive: Bool, enabledProviders: Set<ProviderID>) {
        self.isActive = isActive
        self.enabledProviders = enabledProviders
    }

    public var canRefresh: Bool {
        isActive && !enabledProviders.isEmpty
    }
}

/// Reports display sleep and wake. The live implementation observes `NSWorkspace`.
@MainActor public protocol DisplayStateMonitoring: AnyObject {
    var isDisplayAsleep: Bool { get }
    var onSleep: (() -> Void)? { get set }
    var onWake: (() -> Void)? { get set }
}

extension DisplaySleepMonitor: DisplayStateMonitoring {}

/// Decides when providers refresh. ``UsageStore`` decides how.
///
/// One global cadence: every 300 s while the display is awake. Opening the popover refreshes
/// quota readings at least 60 s old. Display sleep stops all work; wake refreshes quota
/// readings at least 300 s old. Token history follows its own due rule at each of these
/// events and never adds a quota request. Requests made in the same main-actor turn merge
/// into one store call.
@MainActor
public final class RefreshScheduler {
    public static let interval: TimeInterval = 300
    public static let popoverMaxAge: TimeInterval = 60

    private let store: UsageStore
    private let display: (any DisplayStateMonitoring)?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var configuration: RefreshConfiguration?
    private var timer: Task<Void, Never>?
    private var pendingRequest: Task<Void, Never>?
    private var pendingQuota: Set<ProviderID> = []
    private var pendingHistory: Set<ProviderID> = []
    /// The newest store call, so tests can wait for the work that an event caused.
    private(set) var latestWork: Task<Void, Never>?

    public init(
        store: UsageStore,
        display: (any DisplayStateMonitoring)?,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.store = store
        self.display = display
        self.sleep = sleep
        display?.onSleep = { [weak self] in self?.displayDidSleep() }
        display?.onWake = { [weak self] in self?.displayDidWake() }
    }

    /// Applies new settings. Starting or resuming refreshes every enabled provider; later
    /// changes refresh only newly enabled providers.
    public func update(_ configuration: RefreshConfiguration) {
        let previous = self.configuration
        self.configuration = configuration
        store.setEnabled(configuration.enabledProviders)
        pendingQuota.formIntersection(configuration.enabledProviders)
        pendingHistory.formIntersection(configuration.enabledProviders)
        guard configuration.canRefresh else {
            cancelWork()
            return
        }
        let alreadyRunning =
            previous?.canRefresh == true ? previous?.enabledProviders ?? [] : []
        let started = configuration.enabledProviders.subtracting(alreadyRunning)
        request(quota: started, history: started)
        startTimer()
    }

    /// Refreshes quota and history of `ids` now, superseding work in progress. Use after
    /// credential, account, or source changes.
    public func refreshNow(_ ids: Set<ProviderID>) {
        store.cancel(ids)
        request(quota: ids, history: ids, force: true)
    }

    public func popoverDidOpen() {
        request(quota: due(maxAge: Self.popoverMaxAge), history: enabledProviders)
    }

    public func stop() {
        configuration = nil
        cancelWork()
    }

    func displayDidSleep() {
        cancelWork()
    }

    func displayDidWake() {
        request(quota: due(maxAge: Self.interval), history: enabledProviders)
        startTimer()
    }

    /// Waits for the newest store call to finish. For tests.
    func waitForWork() async {
        await latestWork?.value
    }

    private var enabledProviders: Set<ProviderID> {
        configuration?.enabledProviders ?? []
    }

    private func due(maxAge: TimeInterval) -> Set<ProviderID> {
        enabledProviders.filter { store.needsRefresh($0, maxAge: maxAge) }
    }

    private func cancelWork() {
        timer?.cancel()
        timer = nil
        pendingRequest?.cancel()
        pendingRequest = nil
        pendingQuota.removeAll()
        pendingHistory.removeAll()
        store.cancel()
    }

    private func startTimer() {
        guard configuration?.canRefresh == true, display?.isDisplayAsleep != true, timer == nil
        else { return }
        timer = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(Self.interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.request(quota: self.enabledProviders, history: self.enabledProviders)
            }
        }
    }

    /// Queues quota refreshes for `quota` and history refreshes for `history`. Without
    /// `force`, quota already refreshing and history that is not due are left out; forcing
    /// applies only to these ids, never to others that merge into the same store call.
    private func request(quota: Set<ProviderID>, history: Set<ProviderID>, force: Bool = false) {
        guard let configuration, configuration.canRefresh, display?.isDisplayAsleep != true else {
            return
        }
        var quota = quota.intersection(configuration.enabledProviders)
        var history = history.intersection(configuration.enabledProviders)
        if !force {
            quota.subtract(store.refreshing)
            history = history.filter(store.historyNeedsRefresh)
        }
        guard !quota.isEmpty || !history.isEmpty else { return }
        pendingQuota.formUnion(quota)
        pendingHistory.formUnion(history)
        guard pendingRequest == nil else { return }
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let quota = self.pendingQuota
            let history = self.pendingHistory
            self.pendingQuota.removeAll()
            self.pendingHistory.removeAll()
            self.pendingRequest = nil
            await self.store.refresh(quota: quota, history: history)
        }
        pendingRequest = task
        latestWork = task
    }
}

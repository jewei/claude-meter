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

/// Reports whether the Mac is under strain. The live implementation observes Low Power Mode
/// and the thermal state.
@MainActor public protocol PowerStateMonitoring: AnyObject {
    var isConstrained: Bool { get }
    var onChange: (() -> Void)? { get set }
}

extension PowerStateMonitor: PowerStateMonitoring {}

/// Decides when providers refresh. ``UsageStore`` decides how.
///
/// One global cadence: every 300 s while the display is awake, or every 900 s while the Mac is
/// under strain (Low Power Mode, or a serious or critical thermal state). The first wait after
/// each start of the timer is always 300 s, so every start path behaves as without strain.
/// Opening the popover refreshes quota readings at least 60 s old. Display sleep stops all
/// work; wake refreshes quota readings at least 300 s old. Token history follows its own due
/// rule at each of these events and never adds a quota request. Requests made in the same
/// main-actor turn merge into one store call.
@MainActor
public final class RefreshScheduler {
    public nonisolated static let interval: TimeInterval = 300
    public nonisolated static let constrainedInterval: TimeInterval = 900
    public nonisolated static let popoverMaxAge: TimeInterval = 60
    /// An observation older than this is stale at the normal cadence: one interval plus 600 s.
    /// The 600 s cover Claude's 290 s skip of an account that it checked recently, the 90 s
    /// request deadline, and a late wake: a healthy reading is at most 300 + 290 + 90 s old.
    public nonisolated static let staleAfter: TimeInterval = 900
    /// The same under strain: 900 s plus the same 600 s. A healthy reading is at most
    /// 900 + 290 + 90 s old.
    public nonisolated static let constrainedStaleAfter: TimeInterval = 1_500
    /// After strain ends, the strain limit holds this long: the first tick after the restart
    /// (300 s) plus its 90 s request deadline.
    public nonisolated static let strainGrace: TimeInterval = 390

    private let store: UsageStore
    private let display: (any DisplayStateMonitoring)?
    private let power: (any PowerStateMonitoring)?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    /// When strain last ended, for ``staleAfter(at:)``.
    private var leftStrainAt: Date?
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
        power: (any PowerStateMonitoring)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.store = store
        self.display = display
        self.power = power
        self.now = now
        self.sleep = sleep
        display?.onSleep = { [weak self] in self?.displayDidSleep() }
        display?.onWake = { [weak self] in self?.displayDidWake() }
        power?.onChange = { [weak self] in self?.powerDidChange() }
    }

    /// Whether the Mac is under strain now.
    public var isConstrained: Bool { power?.isConstrained == true }

    /// The cadence after the first tick: 900 s under strain, else 300 s.
    public var currentInterval: TimeInterval {
        isConstrained ? Self.constrainedInterval : Self.interval
    }

    /// How old an observation can be at `date` and still be current. The strain limit holds
    /// for ``strainGrace`` after strain ends, so readings from the slower cadence do not show
    /// as stale while their refresh runs.
    public func staleAfter(at date: Date) -> TimeInterval {
        if isConstrained { return Self.constrainedStaleAfter }
        if let leftStrainAt, date < leftStrainAt.addingTimeInterval(Self.strainGrace) {
            return Self.constrainedStaleAfter
        }
        return Self.staleAfter
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
    /// credential, account, or source changes. While paused, before onboarding, or with the
    /// display asleep, no request goes out; the change is applied from local reads only
    /// (``UsageStore/reconcile(_:)``), so a removed account or login disappears at once.
    public func refreshNow(_ ids: Set<ProviderID>) {
        guard canRequest else {
            let ids = ids.intersection(enabledProviders)
            guard !ids.isEmpty else { return }
            latestWork = Task { [store] in await store.reconcile(ids) }
            return
        }
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

    /// Entering strain changes nothing now: the tick already waiting fires, and the waits
    /// after it are longer. Leaving strain refreshes what is due, as a wake does, and restarts
    /// the timer, so the next tick is 300 s away instead of up to 900 s.
    func powerDidChange() {
        guard !isConstrained else { return }
        leftStrainAt = now()
        request(quota: due(maxAge: Self.interval), history: enabledProviders)
        // Only the timer restarts. `cancelWork()` would also cancel store work in flight.
        timer?.cancel()
        timer = nil
        startTimer()
    }

    /// Waits for the newest store call to finish. For tests.
    func waitForWork() async {
        await latestWork?.value
    }

    private var enabledProviders: Set<ProviderID> {
        configuration?.enabledProviders ?? []
    }

    /// Requests may go out: refreshing is active and the display is awake.
    var canRequest: Bool {
        configuration?.canRefresh == true && display?.isDisplayAsleep != true
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
        guard canRequest, timer == nil else { return }
        timer = Task { [weak self, sleep] in
            // The first wait is always the normal interval (type comment).
            var wait = Self.interval
            while !Task.isCancelled {
                do { try await sleep(wait) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.request(quota: self.enabledProviders, history: self.enabledProviders)
                wait = self.currentInterval
            }
        }
    }

    /// Queues quota refreshes for `quota` and history refreshes for `history`. Without
    /// `force`, quota already refreshing and history that is not due are left out; forcing
    /// applies only to these ids, never to others that merge into the same store call.
    private func request(quota: Set<ProviderID>, history: Set<ProviderID>, force: Bool = false) {
        guard canRequest, let configuration else { return }
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

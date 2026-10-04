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
/// readings at least 60 s old. Display sleep stops all work; wake refreshes readings at least
/// 300 s old. Requests made in the same main-actor turn merge into one store call.
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
    private var pending: Set<ProviderID> = []
    private var pendingForcesHistory = false

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
        pending.formIntersection(configuration.enabledProviders)
        guard configuration.canRefresh else {
            cancelWork()
            return
        }
        let alreadyRunning =
            previous?.canRefresh == true ? previous?.enabledProviders ?? [] : []
        request(configuration.enabledProviders.subtracting(alreadyRunning))
        startTimer()
    }

    /// Refreshes `ids` now, superseding work in progress. Use after credential, account, or
    /// source changes.
    public func refreshNow(_ ids: Set<ProviderID>) {
        store.cancel(ids)
        request(ids, forceHistory: true)
    }

    public func popoverDidOpen() {
        request(due(maxAge: Self.popoverMaxAge))
    }

    public func stop() {
        configuration = nil
        cancelWork()
    }

    func displayDidSleep() {
        cancelWork()
    }

    func displayDidWake() {
        request(due(maxAge: Self.interval))
        startTimer()
    }

    private func due(maxAge: TimeInterval) -> Set<ProviderID> {
        (configuration?.enabledProviders ?? []).filter {
            store.needsRefresh($0, maxAge: maxAge)
        }
    }

    private func cancelWork() {
        timer?.cancel()
        timer = nil
        pendingRequest?.cancel()
        pendingRequest = nil
        pending.removeAll()
        pendingForcesHistory = false
        store.cancel()
    }

    private func startTimer() {
        guard configuration?.canRefresh == true, display?.isDisplayAsleep != true, timer == nil
        else { return }
        timer = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(Self.interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.request(self.configuration?.enabledProviders ?? [])
            }
        }
    }

    private func request(_ ids: Set<ProviderID>, forceHistory: Bool = false) {
        guard let configuration, configuration.canRefresh, display?.isDisplayAsleep != true else {
            return
        }
        let wanted = ids.intersection(configuration.enabledProviders)
        let new = forceHistory ? wanted : wanted.subtracting(store.refreshing)
        guard !new.isEmpty else { return }
        pending.formUnion(new)
        pendingForcesHistory = pendingForcesHistory || forceHistory
        guard pendingRequest == nil else { return }
        pendingRequest = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let ids = self.pending
            let forceHistory = self.pendingForcesHistory
            self.pending.removeAll()
            self.pendingForcesHistory = false
            self.pendingRequest = nil
            await self.store.refresh(ids, forceHistory: forceHistory)
        }
    }
}

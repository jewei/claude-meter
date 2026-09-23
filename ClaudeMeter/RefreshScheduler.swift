import ClaudeMeterCore
import Foundation

struct RefreshConfiguration: Equatable, Sendable {
    let isActive: Bool
    let enabledProviders: Set<ProviderID>

    var canRefresh: Bool { isActive && !enabledProviders.isEmpty }
}

/// Owns refresh timing. UsageStore owns provider execution and publication.
@MainActor
final class RefreshScheduler {
    static let backgroundInterval: TimeInterval = 300
    static let interactiveMaxAge: TimeInterval = 60

    private let usageStore: UsageStore
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let isDisplayAsleep: @MainActor () -> Bool
    private let powerMonitor: PowerMonitor?
    private var configuration: RefreshConfiguration?
    private var timerTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var pending: Set<ProviderID> = []

    init(
        usageStore: UsageStore,
        powerMonitor: PowerMonitor? = PowerMonitor(),
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        isDisplayAsleep: (@MainActor () -> Bool)? = nil
    ) {
        self.usageStore = usageStore
        self.powerMonitor = powerMonitor
        self.now = now
        self.sleep = sleep
        self.isDisplayAsleep = isDisplayAsleep ?? { powerMonitor?.isDisplayAsleep ?? false }
        powerMonitor?.onDisplaySleep = { [weak self] in self?.displayDidSleep() }
        powerMonitor?.onWake = { [weak self] in self?.displayDidWake() }
    }

    deinit {
        timerTask?.cancel()
        requestTask?.cancel()
    }

    /// Start/resume immediately; later enablement changes refresh only added providers.
    func update(configuration: RefreshConfiguration) {
        let previous = self.configuration
        self.configuration = configuration
        for id in ProviderID.allCases {
            usageStore.setEnabled(id, enabled: configuration.enabledProviders.contains(id))
        }
        pending.formIntersection(configuration.enabledProviders)
        guard configuration.canRefresh else {
            cancelWork()
            return
        }
        let alreadyEnabled = previous?.canRefresh == true ? previous?.enabledProviders ?? [] : []
        request(configuration.enabledProviders.subtracting(alreadyEnabled))
        startTimer()
    }

    func stop() {
        configuration = nil
        cancelWork()
    }

    /// Explicit requests bypass the freshness threshold and supersede affected work only.
    func refreshNow() {
        refresh(configuration?.enabledProviders ?? [])
    }

    /// Used after credentials, accounts, or source settings change.
    func refresh(_ providers: Set<ProviderID>) {
        usageStore.cancel(providers)
        request(providers)
    }

    func popoverDidOpen() {
        request(providersNeedingRefresh(maxAge: Self.interactiveMaxAge))
    }

    func displayDidSleep() {
        cancelWork()
    }

    func displayDidWake() {
        request(providersNeedingRefresh(maxAge: Self.backgroundInterval))
        startTimer()
    }

    private func providersNeedingRefresh(maxAge: TimeInterval) -> Set<ProviderID> {
        let date = now()
        return Set(
            (configuration?.enabledProviders ?? []).filter {
                usageStore.reading(for: $0)?.needsRefresh(now: date, maxAge: maxAge) ?? true
            })
    }

    private func cancelWork() {
        timerTask?.cancel()
        timerTask = nil
        requestTask?.cancel()
        requestTask = nil
        pending.removeAll()
        usageStore.cancel()
    }

    private func startTimer() {
        guard configuration?.canRefresh == true, !isDisplayAsleep(), timerTask == nil else {
            return
        }
        timerTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(Self.backgroundInterval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.request(self.configuration?.enabledProviders ?? [])
            }
        }
    }

    private func request(_ providers: Set<ProviderID>) {
        guard let configuration, configuration.canRefresh, !isDisplayAsleep() else { return }
        pending.formUnion(
            providers.intersection(configuration.enabledProviders).subtracting(
                usageStore.refreshing))
        guard !pending.isEmpty, requestTask == nil else { return }
        // Merge events from the same actor turn. Once work starts, UsageStore's
        // refreshing set prevents automatic requests from duplicating it.
        requestTask = Task { [weak self, usageStore] in
            guard !Task.isCancelled, let request = self?.takeRequest() else { return }
            await usageStore.refresh(request.providers, now: request.date)
        }
    }

    private func takeRequest() -> (providers: Set<ProviderID>, date: Date) {
        let providers = pending
        pending.removeAll()
        requestTask = nil
        return (providers, now())
    }
}

import SwiftUI
import WidgetKit
import ClaudeMeterCore

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: ClaudeUsageSnapshot? = nil
    @Published var lastPollResult: ParseResult? = nil
    @Published var isLoading = false
    @Published var lastError: String? = nil
    @Published var lastPolledAt: Date? = nil
    @Published var isPopoverOpen = false

    var pipeline: any ClaudeMeterPipeline
    let notificationEngine = NotificationEngine()
    private(set) var historyStore: HistoryStore?
    private(set) var storeDirectory: URL = FileManager.default.temporaryDirectory
    private var pollTask: Task<Void, Never>?
    private var backoffSeconds: Double = 0

    private static func makeStore() -> SnapshotStore {
        if let shared = try? SnapshotStore.appGroup(suiteName: AppGroupConfig.suiteName) {
            if let legacy = try? SnapshotStore.applicationSupport() {
                try? SnapshotStore.migrateSnapshotIfNeeded(from: legacy, to: shared)
            }
            return shared
        }
        if let legacy = try? SnapshotStore.applicationSupport() {
            return legacy
        }
        return SnapshotStore(directory: FileManager.default.temporaryDirectory)
    }

    init() {
        AppGroupConfig.syncDisplaySettings()
        let store = AppState.makeStore()
        self.storeDirectory = store.directory
        self.historyStore = try? HistoryStore(
            directory: store.directory,
            retentionDays: Self.historyRetentionDays()
        )
        self.pipeline = AppState.makePipeline(store: store)
        self.snapshot = try? store.readLatest()
        self.lastPolledAt = snapshot?.lastSuccessfulPollAt
        if snapshot == nil, let record = try? store.readLastError() {
            self.lastError = record.message
        }
        startPolling()
        Task { await notificationEngine.requestAuthorizationIfNeeded() }
    }

    init(pipeline: any ClaudeMeterPipeline, initialSnapshot: ClaudeUsageSnapshot? = nil) {
        self.pipeline = pipeline
        self.snapshot = initialSnapshot
        self.lastPolledAt = initialSnapshot?.lastSuccessfulPollAt
    }

    deinit {
        pollTask?.cancel()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.poll()
            while !Task.isCancelled {
                guard let self else { break }
                let ud = UserDefaults.standard
                let activeInterval = ud.double(forKey: "pollIntervalActiveSeconds").positive ?? 15
                let backgroundInterval = ud.double(forKey: "pollIntervalBackgroundSeconds").positive ?? 60
                let interval = self.isPopoverOpen ? activeInterval : backgroundInterval
                let effective = self.backoffSeconds > 0 ? max(interval, self.backoffSeconds) : interval
                try? await Task.sleep(for: .seconds(effective))
                guard !Task.isCancelled else { break }
                await self.poll()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshNow() {
        Task { await poll() }
    }

    func popoverDidOpen() {
        isPopoverOpen = true
        refreshNow()
    }

    func popoverDidClose() {
        isPopoverOpen = false
    }

    var isStale: Bool {
        guard let polledAt = snapshot?.lastSuccessfulPollAt else { return false }
        let threshold = UserDefaults.standard.double(forKey: "staleAfterSeconds").positive ?? 180
        return Date().timeIntervalSince(polledAt) > threshold
    }

    func rebuildPipeline() {
        let store = AppState.makeStore()
        storeDirectory = store.directory
        historyStore = try? HistoryStore(
            directory: store.directory,
            retentionDays: Self.historyRetentionDays()
        )
        pipeline = AppState.makePipeline(store: store)
        startPolling()
    }

    func setHistoryRetentionDays(_ days: Int) {
        try? historyStore?.setRetentionDays(days)
    }

    static func historyRetentionDays(defaults: UserDefaults = .standard) -> Int {
        let days = defaults.integer(forKey: "historyRetentionDays")
        return days > 0 ? days : 180
    }

    var severity: UsageSeverity {
        guard let snap = snapshot else { return .unknown }
        let thresholds = Self.currentThresholds()
        return UsageSeverity.highest(
            thresholds.severity(for: snap.limits.currentSession.percentUsed),
            thresholds.severity(for: snap.limits.currentWeekAllModels.percentUsed)
        )
    }

    static func currentThresholds() -> UsageThresholds {
        AppGroupConfig.currentThresholds()
    }

    private func poll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await pipeline.poll(now: Date())
            lastPollResult = result

            if result.isFatal {
                lastError = result.errors.map(\.message).joined(separator: "; ")
                applyBackoff()
                return
            }

            let previous = snapshot
            if let snap = result.snapshot {
                snapshot = snap
                lastPolledAt = snap.lastSuccessfulPollAt ?? Date()
                let record = HistoryRecord(
                    from: snap,
                    thresholds: AppGroupConfig.currentThresholds()
                )
                if let hs = historyStore {
                    Task.detached(priority: .utility) { try? hs.append(record) }
                }
                await notificationEngine.process(
                    snapshot: snap,
                    previous: previous,
                    isStale: false
                )
                WidgetCenter.shared.reloadAllTimelines()
            }
            lastError = nil
            backoffSeconds = 0
        } catch {
            lastError = String(describing: error)
            applyBackoff()
        }
    }

    private func applyBackoff() {
        backoffSeconds = backoffSeconds == 0 ? 15 : min(backoffSeconds * 2, 300)
    }

    // MARK: - Pipeline factory

    private static func makePipeline(store: SnapshotStore) -> any ClaudeMeterPipeline {
        let statsPipeline = StatsCachePipeline(store: store)
        if let creds = ClaudeAIKeychain.load() {
            let client = ClaudeAIUsageClient(sessionKey: creds.sessionKey, orgId: creds.orgId)
            return ClaudeAIPipeline(client: client, store: store, fallback: statsPipeline)
        }
        return statsPipeline
    }
}

// MARK: - UserDefaults helper

private extension Double {
    var positive: Double? { self > 0 ? self : nil }
}

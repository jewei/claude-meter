import AppKit
import SwiftUI
import WidgetKit
import ClaudeMeterCore
import Sparkle

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: ClaudeUsageSnapshot? = nil
    @Published var lastPollResult: ParseResult? = nil
    @Published var isLoading = false
    @Published var lastError: String? = nil
    @Published var lastPolledAt: Date? = nil
    @Published var isPopoverOpen = false
    @Published var updateAvailable = false

    var pipeline: any ClaudeMeterPipeline
    let notificationEngine = NotificationEngine()
    private let updaterDelegate: UpdaterDelegate
    private let updaterController: SPUStandardUpdaterController
    private(set) var historyStore: HistoryStore?
    private(set) var storeDirectory: URL = FileManager.default.temporaryDirectory
    private var pollTask: Task<Void, Never>?
    private var backoffSeconds: Double = 0
    private var pipelineGeneration = 0
    private var refreshPending = false

    var primarySourceWarning: String? {
        lastPollResult?.warnings.first { $0.field == "claude.ai API" }?.message
    }

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
        // Create delegate and controller before self is fully available so we can pass the
        // delegate reference at construction time (SPUStandardUpdaterController doesn't
        // allow changing its user driver delegate after init).
        let delegate = UpdaterDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: delegate
        )
        self.updaterDelegate = delegate
        self.updaterController = controller
        self.pipeline = AppState.makePipeline(store: store)
        // Self is fully initialized from here on.
        self.storeDirectory = store.directory
        self.historyStore = try? HistoryStore(
            directory: store.directory,
            retentionDays: Self.historyRetentionDays()
        )
        self.snapshot = try? store.readLatest()
        self.lastPolledAt = snapshot?.lastSuccessfulPollAt
        if snapshot == nil, let record = try? store.readLastError() {
            self.lastError = record.message
        }
        delegate.appState = self
        startPolling()
        Task { await notificationEngine.requestAuthorizationIfNeeded() }
    }

    init(pipeline: any ClaudeMeterPipeline, initialSnapshot: ClaudeUsageSnapshot? = nil) {
        let delegate = UpdaterDelegate()
        self.updaterDelegate = delegate
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: delegate
        )
        self.pipeline = pipeline
        self.snapshot = initialSnapshot
        self.lastPolledAt = initialSnapshot?.lastSuccessfulPollAt
        delegate.appState = self
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

    func checkForUpdates() {
        NSApp.setActivationPolicy(.regular)
        updaterController.updater.checkForUpdates()
    }

    func refreshNow() {
        if isLoading {
            refreshPending = true
            return
        }
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
        pipelineGeneration += 1
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
        let generation = pipelineGeneration
        guard !isLoading else {
            refreshPending = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            if refreshPending {
                refreshPending = false
                Task { await poll() }
            }
        }

        do {
            let result = try await pipeline.poll(now: Date())
            guard generation == pipelineGeneration else { return }

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
                    isStale: isStale || snap.state.isStale
                )
                if shouldReloadWidget(previous: previous, current: snap) {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }

            if let apiWarning = result.warnings.first(where: { $0.field == "claude.ai API" }) {
                lastError = apiWarning.message
            } else {
                lastError = nil
            }
            backoffSeconds = 0
        } catch {
            guard generation == pipelineGeneration else { return }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            applyBackoff()
        }
    }

    private func shouldReloadWidget(
        previous: ClaudeUsageSnapshot?,
        current: ClaudeUsageSnapshot
    ) -> Bool {
        guard let previous else { return true }
        return previous.limits != current.limits
            || previous.state.severity != current.state.severity
            || previous.lastSuccessfulPollAt != current.lastSuccessfulPollAt
    }

    private func applyBackoff() {
        backoffSeconds = backoffSeconds == 0 ? 15 : min(backoffSeconds * 2, 300)
    }

    // MARK: - Pipeline factory

    private static func makePipeline(store: SnapshotStore) -> any ClaudeMeterPipeline {
        let thresholds = AppGroupConfig.currentThresholds()
        let statsPipeline = StatsCachePipeline(store: store, thresholds: thresholds)
        if let creds = ClaudeAIKeychain.load() {
            let client = ClaudeAIUsageClient(sessionKey: creds.sessionKey, orgId: creds.orgId)
            return ClaudeAIPipeline(
                client: client,
                store: store,
                fallback: statsPipeline,
                thresholds: thresholds
            )
        }
        return statsPipeline
    }
}

// MARK: - Sparkle user driver delegate

// @unchecked Sendable + nonisolated(unsafe): Sparkle calls these from the main thread;
// mutations hop to MainActor via Task for safe off-main fallback.
private final class UpdaterDelegate: NSObject, SPUStandardUserDriverDelegate, @unchecked Sendable {
    nonisolated(unsafe) weak var appState: AppState?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Delegate handles background scheduled checks (immediateFocus == false);
        // let Sparkle handle any check the user explicitly triggered.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            if handleShowingUpdate {
                NSApp.setActivationPolicy(.regular)
            } else {
                appState.updateAvailable = true
                await appState.notificationEngine.postUpdateAvailable(
                    version: update.displayVersionString
                )
            }
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor [weak appState] in
            appState?.updateAvailable = false
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor [weak appState] in
            appState?.updateAvailable = false
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - UserDefaults helper

private extension Double {
    var positive: Double? { self > 0 ? self : nil }
}

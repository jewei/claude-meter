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
    @Published private(set) var isActive: Bool
    @Published private(set) var hasEnabledDataSource: Bool

    // Cursor is a parallel, optional source (separate billing model from Claude).
    @Published var cursorUsage: CursorUsage? = nil
    @Published var cursorError: String? = nil
    @Published var cursorLastPolledAt: Date? = nil
    private let cursorProvider = CursorUsageProvider()

    var pipeline: any ClaudeMeterPipeline
    let notificationEngine = NotificationEngine()
    private let store: SnapshotStore
    private let updaterDelegate: UpdaterDelegate
    private let updaterController: SPUStandardUpdaterController
    private var pollTask: Task<Void, Never>?
    private var pipelineGeneration = 0
    private var refreshPending = false

    private static let pollIntervalSeconds: TimeInterval = 60

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
        UserDefaults.standard.register(defaults: [
            AppSettings.statuslineSourceEnabledKey: true,
        ])
        AppGroupConfig.syncDisplaySettings()
        let store = AppState.makeStore()
        self.store = store
        self.isActive = AppSettings.isActive
        self.hasEnabledDataSource = AppSettings.hasEnabledDataSource
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
        self.store = SnapshotStore(directory: FileManager.default.temporaryDirectory)
        self.isActive = true
        self.hasEnabledDataSource = true
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
        guard canPoll else {
            pollTask = nil
            return
        }
        installStatuslineBridgeIfNeeded()
        pollTask = Task { [weak self] in
            await self?.poll()
            while !Task.isCancelled {
                guard let self else { break }
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
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
        guard canPoll else { return }
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
        let claudeStale = AppGroupConfig.isSnapshotStale(lastPollAt: snapshot?.lastSuccessfulPollAt)
        let cursorStale = AppSettings.cursorSourceEnabled
            && cursorUsage != nil
            && AppGroupConfig.isSnapshotStale(lastPollAt: cursorLastPolledAt)
        return claudeStale || cursorStale
    }

    var cursorIsStale: Bool {
        AppGroupConfig.isSnapshotStale(lastPollAt: cursorLastPolledAt)
    }

    func setCursorSourceEnabled(_ enabled: Bool) {
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        if enabled {
            if isActive { startPolling() }
        } else {
            clearCursorState()
            if canPoll {
                // Claude sources may still be enabled.
            } else {
                stopPolling()
                isLoading = false
            }
        }
    }

    func clearCursorState() {
        cursorUsage = nil
        cursorError = nil
        cursorLastPolledAt = nil
    }

    func rebuildPipeline() {
        pipelineGeneration += 1
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        pipeline = AppState.makePipeline(store: store)
        startPolling()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        AppSettings.isActive = active
        isActive = active
        refreshPending = false
        if active {
            rebuildPipeline()
        } else {
            stopPolling()
            isLoading = false
        }
    }

    var severity: UsageSeverity {
        let thresholds = Self.currentThresholds()
        var result: UsageSeverity = .unknown
        if let snap = snapshot {
            result = UsageSeverity.highest(
                result,
                thresholds.severity(for: snap.limits.currentSession.percentUsed)
            )
            result = UsageSeverity.highest(
                result,
                thresholds.severity(for: snap.limits.currentWeekAllModels.percentUsed)
            )
        }
        if AppSettings.cursorSourceEnabled, let cursor = cursorUsage {
            result = UsageSeverity.highest(result, thresholds.severity(for: cursor.percentUsed))
        }
        return result
    }

    static func currentThresholds() -> UsageThresholds {
        AppGroupConfig.currentThresholds()
    }

    private func poll() async {
        guard canPoll else { return }
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

        if AppSettings.hasClaudeSource {
            async let claude: Void = pollClaude(generation: generation)
            if AppSettings.cursorSourceEnabled {
                async let cursor: Void = pollCursor(generation: generation)
                _ = await (claude, cursor)
            } else {
                await claude
            }
        } else if AppSettings.cursorSourceEnabled {
            await pollCursor(generation: generation)
        }
    }

    private func pollClaude(generation: Int) async {
        do {
            let result = try await pipeline.poll(now: Date())
            guard generation == pipelineGeneration, canPoll else { return }

            lastPollResult = result

            if result.isFatal {
                lastError = result.errors.map(\.message).joined(separator: "; ")
                return
            }

            let previous = snapshot
            if let snap = result.snapshot {
                snapshot = snap
                lastPolledAt = snap.lastSuccessfulPollAt ?? Date()
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
        } catch {
            guard generation == pipelineGeneration, canPoll else { return }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Cursor runs independently of the Claude pipeline so a Cursor failure never
    /// affects Claude state (and vice versa).
    private func pollCursor(generation: Int) async {
        do {
            let usage = try await cursorProvider.fetchUsage(now: Date())
            guard generation == pipelineGeneration, canPoll else { return }
            cursorUsage = usage
            cursorError = nil
            cursorLastPolledAt = Date()
        } catch {
            guard generation == pipelineGeneration, canPoll else { return }
            switch error {
            case CursorError.notDetected, CursorError.unauthorized, CursorError.forbidden:
                cursorUsage = nil
            default:
                break
            }
            cursorError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    // MARK: - Pipeline factory

    private static func makePipeline(store: SnapshotStore) -> any ClaudeMeterPipeline {
        let thresholds = AppGroupConfig.currentThresholds()
        var pipeline: any ClaudeMeterPipeline = CachedSnapshotPipeline(store: store)

        if AppSettings.claudeAISourceEnabled, let creds = ClaudeAIKeychain.load() {
            let client = ClaudeAIUsageClient(sessionKey: creds.sessionKey, orgId: creds.orgId)
            pipeline = ClaudeAIPipeline(
                client: client,
                store: store,
                fallback: pipeline,
                thresholds: thresholds
            )
        }

        if AppSettings.oauthSourceEnabled {
            pipeline = OAuthPipeline(fallback: pipeline, store: store, thresholds: thresholds)
        }

        if AppSettings.statuslineSourceEnabled {
            pipeline = StatuslinePipeline(fallback: pipeline, store: store, thresholds: thresholds)
        }

        return pipeline
    }

    private var canPoll: Bool {
        isActive && AppSettings.hasEnabledDataSource
    }

    private func installStatuslineBridgeIfNeeded() {
        guard AppSettings.statuslineSourceEnabled else { return }
        let store = store
        Task.detached(priority: .utility) {
            do {
                try StatuslineBridge.install()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                try? store.writeLastError(LastErrorRecord(
                    message: DiagnosticsSanitizer.sanitize(message)
                ))
            }
        }
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

enum AppSettings {
    static let isActiveKey = "isActive"
    static let statuslineSourceEnabledKey = "statuslineSourceEnabled"
    static let oauthSourceEnabledKey = "oauthSourceEnabled"
    static let claudeAISourceEnabledKey = "claudeAISourceEnabled"
    static let cursorSourceEnabledKey = "cursorSourceEnabled"

    static var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: isActiveKey) }
        set { UserDefaults.standard.set(newValue, forKey: isActiveKey) }
    }

    static var statuslineSourceEnabled: Bool {
        get { boolDefaultingTrue(forKey: statuslineSourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: statuslineSourceEnabledKey) }
    }

    static var oauthSourceEnabled: Bool {
        get { boolDefaultingTrue(forKey: oauthSourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: oauthSourceEnabledKey) }
    }

    static var claudeAISourceEnabled: Bool {
        get { boolDefaultingTrue(forKey: claudeAISourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: claudeAISourceEnabledKey) }
    }

    /// Cursor defaults off — it's an opt-in source with a different billing model.
    static var cursorSourceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: cursorSourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: cursorSourceEnabledKey) }
    }

    static var hasClaudeSource: Bool {
        statuslineSourceEnabled || oauthSourceEnabled || claudeAISourceEnabled
    }

    static var hasEnabledDataSource: Bool {
        hasClaudeSource || cursorSourceEnabled
    }

    private static func boolDefaultingTrue(forKey key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}

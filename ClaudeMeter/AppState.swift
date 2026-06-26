import AppKit
import ClaudeMeterCore
import SwiftUI
import WidgetKit

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: ClaudeUsageSnapshot? = nil
    @Published var lastPollResult: ParseResult? = nil
    @Published var isLoading = false
    @Published var lastError: String? = nil
    @Published var lastPolledAt: Date? = nil
    @Published var isPopoverOpen = false
    @Published var updateAvailable = false
    /// Anthropic service status, refreshed alongside Claude polls. Surfaced only
    /// during incidents to distinguish an outage from bad credentials.
    @Published var serviceStatus: ServiceStatus? = nil
    @Published private(set) var isActive: Bool
    @Published private(set) var hasEnabledDataSource: Bool

    // Cursor is a parallel, optional source (separate billing model from Claude).
    @Published var cursorUsage: CursorUsage? = nil
    @Published var cursorError: String? = nil
    @Published var cursorLastPolledAt: Date? = nil
    @Published var costScanPartial = false
    private let cursorProvider = CursorUsageProvider()

    var pipeline: any ClaudeMeterPipeline
    let notificationEngine = NotificationEngine()
    private let store: SnapshotStore
    private let appUpdater: AppUpdater
    private var pollTask: Task<Void, Never>?
    private var rebuildDebounceTask: Task<Void, Never>?
    private var pipelineGeneration = 0
    private var refreshPending = false
    /// False until the first successful in-session poll. The first poll's
    /// `previous` is the persisted snapshot, which must not seed notifications
    /// (e.g. a "refueled" for a window that reset while the app was quit).
    private var didPollInSession = false
    private var powerMonitor: PowerMonitor?
    private var lastOAuthEnrichmentAt: Date?
    private var cachedOAuthEnrichment: OAuthPipeline.OAuthEnrichment?
    /// In-flight statusline-bridge install task; cancelled and replaced on each
    /// refresh so rapid source/account toggles don't pile up or race.
    private var configRefreshTask: Task<Void, Never>?

    private static let pollIntervalSeconds: TimeInterval = 60
    private static let oauthEnrichmentIntervalSeconds: TimeInterval = 300
    private static let rebuildDebounceMilliseconds: UInt64 = 300
    /// How much to stretch the poll cadence while on battery, to cut idle drain
    /// when unplugged. Restored automatically on the next tick after plugging in.
    private static let batteryPollMultiplier: Double = 2
    /// While the display/system is asleep the loop skips polling entirely and
    /// re-checks at this slow cadence; `PowerMonitor.onWake` provides immediacy,
    /// so this is only a safety net (e.g. a missed wake notification).
    private static let asleepRecheckSeconds: TimeInterval = 300

    var primarySourceWarning: String? {
        lastPollResult?.warnings.first { $0.field == "claude.ai API" }?.message
    }

    /// Per-account usage rows for accounts other than the active one (for the
    /// popover's multi-account section). Empty for the common single-account case.
    var otherAccounts: [AccountUsage] {
        snapshot?.accounts?.filter { !$0.isActive } ?? []
    }

    /// Label of the account currently mirrored into the menu bar / top-level fields.
    var activeAccountLabel: String? {
        snapshot?.accounts?.first(where: { $0.isActive })?.label
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
            AppSettings.statuslineSourceEnabledKey: true
        ])
        AppGroupConfig.syncDisplaySettings()
        let store = AppState.makeStore()
        self.store = store
        self.isActive = AppSettings.isActive
        self.hasEnabledDataSource = AppSettings.hasEnabledDataSource
        let appUpdater = AppUpdater(startingUpdater: true)
        self.appUpdater = appUpdater
        self.pipeline = AppState.makePipeline(store: store)
        // Self is fully initialized from here on.
        self.snapshot = try? store.readLatest()
        self.lastPolledAt = snapshot?.lastSuccessfulPollAt
        if snapshot == nil, let record = try? store.readLastError() {
            self.lastError = record.message
        }
        appUpdater.appState = self
        let monitor = PowerMonitor()
        monitor.onWake = { [weak self] in self?.refreshNow() }
        self.powerMonitor = monitor
        startPolling()
        Task { await notificationEngine.requestAuthorizationIfNeeded() }
    }

    init(pipeline: any ClaudeMeterPipeline, initialSnapshot: ClaudeUsageSnapshot? = nil) {
        self.store = SnapshotStore(directory: FileManager.default.temporaryDirectory)
        self.isActive = true
        self.hasEnabledDataSource = true
        let appUpdater = AppUpdater(startingUpdater: false)
        self.appUpdater = appUpdater
        self.pipeline = pipeline
        self.snapshot = initialSnapshot
        self.lastPolledAt = initialSnapshot?.lastSuccessfulPollAt
        appUpdater.appState = self
    }

    deinit {
        pollTask?.cancel()
        rebuildDebounceTask?.cancel()
        configRefreshTask?.cancel()
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
                // Energy-aware cadence: skip work entirely while the display is
                // asleep (PowerMonitor.onWake handles the immediate refresh on
                // wake), and stretch the interval on battery to reduce drain.
                let interval: TimeInterval
                if self.powerMonitor?.isDisplayAsleep == true {
                    interval = Self.asleepRecheckSeconds
                } else if self.powerMonitor?.isOnBattery == true {
                    interval = Self.pollIntervalSeconds * Self.batteryPollMultiplier
                } else {
                    interval = Self.pollIntervalSeconds
                }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                // Re-check: the display may have gone to sleep during the wait.
                guard self.powerMonitor?.isDisplayAsleep != true else { continue }
                await self.poll()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func checkForUpdates() {
        appUpdater.checkForUpdates()
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

    var claudeIsStale: Bool {
        AppGroupConfig.isSnapshotStale(lastPollAt: snapshot?.lastSuccessfulPollAt)
    }

    var isStale: Bool {
        let cursorStale =
            AppSettings.cursorSourceEnabled
            && cursorUsage != nil
            && AppGroupConfig.isSnapshotStale(lastPollAt: cursorLastPolledAt)
        let claudeStale = claudeIsStale || snapshot?.state.isStale == true
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
            pipelineGeneration += 1
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

    /// Debounced rebuild for source toggles — avoids restarting the poll loop on every flip.
    func scheduleRebuildPipeline() {
        rebuildDebounceTask?.cancel()
        rebuildDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.rebuildDebounceMilliseconds))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.rebuildPipeline() }
        }
    }

    func rebuildPipeline() {
        pipelineGeneration += 1
        lastOAuthEnrichmentAt = nil
        cachedOAuthEnrichment = nil
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        pipeline = AppState.makePipeline(store: store)
        installStatuslineBridgeIfNeeded()
        if canPoll && pollTask == nil {
            startPolling()
        } else if !canPoll {
            stopPolling()
            isLoading = false
        }
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

    /// Limit sets the menu bar considers: the **pinned account** when the user set
    /// one (`AppGroupConfig.menuBarAccount`), else **every account** (nearest-limit,
    /// since rate limits are per-account). Cursor is added separately by callers.
    var menuBarLimitSets: [LimitInfo] {
        guard let snap = snapshot else { return [] }
        guard let accounts = snap.accounts, !accounts.isEmpty else { return [snap.limits] }
        let pinned = AppGroupConfig.menuBarAccount
        if pinned != "", pinned != "nearest", let acc = accounts.first(where: { $0.id == pinned }) {
            return [acc.limits]
        }
        return accounts.map(\.limits)
    }

    /// Highest severity across the menu-bar limit sets — the "nearest-limit" signal.
    /// **Claude only**: Cursor is a separate source with its own popover card and is
    /// never folded into the menu bar (it would otherwise dominate the dot/number).
    var severity: UsageSeverity {
        let thresholds = Self.currentThresholds()
        let now = Date()
        var result: UsageSeverity = .unknown
        for limits in menuBarLimitSets {
            let windows = [
                limits.currentSession, limits.currentWeekAllModels, limits.currentWeekOpus,
            ].compactMap { $0 }
            for window in windows {
                result = UsageSeverity.highest(
                    result, thresholds.severity(for: window.resolved(asOf: now).percentUsed))
            }
        }
        return result
    }

    static func currentThresholds() -> UsageThresholds {
        AppGroupConfig.currentThresholds()
    }

    private func poll() async {
        guard canPoll else { return }
        installStatuslineBridgeIfNeeded()
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
        let pipeline = self.pipeline
        let now = Date()
        async let serviceStatusTask: Void = refreshServiceStatus(generation: generation)
        do {
            let result = try await Task.detached {
                try await pipeline.poll(now: now)
            }.value
            await serviceStatusTask
            guard generation == pipelineGeneration, canPoll else { return }

            lastPollResult = result

            if result.isFatal {
                lastError = result.errors.map(\.message).joined(separator: "; ")
                return
            }

            let previous = snapshot
            if var snap = result.snapshot {
                // Enrich with per-model token/cost usage scanned from local logs.
                // Independent of which tier produced the rate-limit snapshot.
                let costResult = await Self.scanCostModels(now: now)
                if !costResult.models.isEmpty { snap.models = costResult.models }
                costScanPartial = costResult.isPartialEstimate
                // Opus weekly, extra-usage spend, and plan live only in the OAuth
                // response. When another source (statusline/claude.ai) produced the
                // snapshot, layer those fields on if OAuth creds are available.
                let enrichment = await oauthEnrichment(for: snap, now: now)
                if let enrichment { Self.apply(enrichment, to: &snap) }
                if !costResult.models.isEmpty || enrichment != nil {
                    try? store.writeLatest(snap)
                }
                snapshot = snap
                lastPolledAt = snap.lastSuccessfulPollAt ?? Date()
                await notificationEngine.process(
                    snapshot: snap,
                    previous: didPollInSession ? previous : nil,
                    isStale: claudeIsStale || snap.state.isStale
                )
                didPollInSession = true
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
            await serviceStatusTask
            guard generation == pipelineGeneration, canPoll else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = DiagnosticsSanitizer.sanitize(message)
        }
    }

    /// Cursor runs independently of the Claude pipeline so a Cursor failure never
    /// affects Claude state (and vice versa).
    private func pollCursor(generation: Int) async {
        let provider = cursorProvider
        let now = Date()
        do {
            let usage = try await Task.detached {
                try await provider.fetchUsage(now: now)
            }.value
            guard generation == pipelineGeneration,
                canPoll,
                AppSettings.cursorSourceEnabled
            else { return }
            cursorUsage = usage
            cursorError = nil
            cursorLastPolledAt = Date()
        } catch {
            guard generation == pipelineGeneration,
                canPoll,
                AppSettings.cursorSourceEnabled
            else { return }
            switch error {
            case CursorError.notDetected, CursorError.unauthorized, CursorError.forbidden:
                cursorUsage = nil
            default:
                break
            }
            cursorError = DiagnosticsSanitizer.sanitize(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// Refreshes Anthropic service status off-main. Advisory only — failures clear
    /// to `nil` so a status outage never masks usage data.
    private func refreshServiceStatus(generation: Int) async {
        let status = await Task.detached(priority: .utility) {
            await AnthropicStatusClient().fetch()
        }.value
        guard generation == pipelineGeneration, canPoll else { return }
        serviceStatus = status
    }

    /// Fetches OAuth-only enrichment (Opus window, extra usage, plan) when the
    /// snapshot came from a non-OAuth source and OAuth creds are available. Returns
    /// `nil` when not applicable. An OAuth-produced snapshot already has these.
    private func oauthEnrichment(
        for snap: ClaudeUsageSnapshot,
        now: Date
    ) async -> OAuthPipeline.OAuthEnrichment? {
        guard AppSettings.oauthSourceEnabled,
            snap.source.cliPath != "api.anthropic.com"
        else { return nil }
        if let lastOAuthEnrichmentAt,
            now.timeIntervalSince(lastOAuthEnrichmentAt) < Self.oauthEnrichmentIntervalSeconds
        {
            return cachedOAuthEnrichment
        }
        lastOAuthEnrichmentAt = now
        if let enrichment = await OAuthPipeline.fetchEnrichment(now: now) {
            cachedOAuthEnrichment = enrichment
            return enrichment
        }
        return cachedOAuthEnrichment
    }

    private static func apply(
        _ e: OAuthPipeline.OAuthEnrichment, to snap: inout ClaudeUsageSnapshot
    ) {
        if let opus = e.opus { snap.limits.currentWeekOpus = opus }
        if let extra = e.extraUsage { snap.limits.extraUsage = extra }
        if let plan = e.plan {
            var account = snap.account ?? AccountInfo()
            account.plan = plan
            snap.account = account
        }
    }

    /// Scans local Claude Code transcripts for per-model token/cost usage (last 7
    /// days), unioned across every discovered config dir (cost is additive).
    /// Discovery happens here, off-main, rather than reusing a cached list — so the
    /// union is correct from the very first poll, independent of the statusline source.
    private static func scanCostModels(now: Date) async -> CostUsageResult {
        await Task.detached(priority: .utility) {
            let accounts = ConfigDirDiscovery.discover(
                configuredDirs: AppGroupConfig.configuredConfigDirs,
                disabledKeys: Set(AppGroupConfig.disabledAccountKeys))
            let paths =
                accounts.isEmpty
                ? [JournalReader.defaultProjectsPath] : accounts.map(\.projectsPath)
            return CostUsageScanner(projectsPaths: paths).scan(daysBack: 7, now: now)
        }.value
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
            pipeline = StatuslinePipeline(
                fallback: pipeline,
                store: store,
                thresholds: thresholds,
                disabledAccountKeys: Set(AppGroupConfig.disabledAccountKeys)
            )
        }

        return pipeline
    }

    private var canPoll: Bool {
        isActive && AppSettings.hasEnabledDataSource
    }

    /// Installs the statusline bridge into every discovered config dir (off-main,
    /// idempotent + self-healing). Coalesces rapid re-invocations (source/account
    /// toggles) by cancelling the prior in-flight task. Cost-scan discovery is
    /// independent (see `scanCostModels`), so this is gated on the statusline source.
    private func installStatuslineBridgeIfNeeded() {
        guard AppSettings.statuslineSourceEnabled else { return }
        let store = store
        let configuredDirs = AppGroupConfig.configuredConfigDirs
        let disabledKeys = Set(AppGroupConfig.disabledAccountKeys)
        configRefreshTask?.cancel()
        configRefreshTask = Task.detached(priority: .utility) {
            let accounts = ConfigDirDiscovery.discover(
                configuredDirs: configuredDirs, disabledKeys: disabledKeys)
            guard !Task.isCancelled else { return }
            do {
                try StatuslineBridge.install(configDirs: accounts.map(\.configDir))
            } catch {
                let message =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                try? store.writeLastError(
                    LastErrorRecord(message: DiagnosticsSanitizer.sanitize(message)))
            }
        }
    }
}

enum AppSettings {
    static let isActiveKey = "isActive"
    static let statuslineSourceEnabledKey = "statuslineSourceEnabled"
    static let oauthSourceEnabledKey = "oauthSourceEnabled"
    static let claudeAISourceEnabledKey = "claudeAISourceEnabled"
    static let cursorSourceEnabledKey = "cursorSourceEnabled"
    static let oauthModeKey = AppGroupConfig.oauthModeKey

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

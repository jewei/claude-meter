import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
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
    /// Latest published Claude Code version (npm), refreshed periodically. Lets the
    /// footer flag when the user's running CLI is behind. nil = unknown (no flag).
    @Published var latestClaudeCodeVersion: String? = nil
    /// Anthropic service status, refreshed alongside Claude polls. Surfaced only
    /// during incidents to distinguish an outage from bad credentials.
    @Published var serviceStatus: ServiceStatus? = nil
    @Published private(set) var isActive: Bool
    @Published private(set) var hasEnabledDataSource: Bool

    // Cursor is a parallel, optional source (separate billing model from Claude).
    @Published private var cursorReading: ReadingState<CursorUsage>?
    @Published private(set) var codexAccounts: [CodexAccountReading] = []
    @Published private var grokReading: ReadingState<GrokUsage>?
    @Published var costScanPartial = false
    /// Activity heatmap (7×24 message counts), scanned on demand when the user
    /// opens it from the cost card. `nil` until first requested.
    @Published var activityHeatmap: ActivityHeatmap? = nil
    @Published var activityHeatmapLoading = false
    private let cursorProvider = CursorUsageProvider()
    private let grokProvider = GrokUsageProvider()

    var pipeline: any ClaudeMeterPipeline
    let notificationEngine = NotificationEngine()
    /// Persisted per-account usage time series; sampled on each successful poll.
    let usageHistory = UsageHistoryStore()
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
    private var networkMonitor: NetworkMonitor?
    private var lastOAuthEnrichmentAt: Date?
    private var cachedOAuthEnrichment: OAuthPipeline.OAuthEnrichment?
    private var lastAccountsFetchAt: Date?
    private var cachedAccountReadings: [OAuthAccountReading] = []
    /// In-flight statusline-bridge install task; cancelled and replaced on each
    /// refresh so rapid source/account toggles don't pile up or race.
    private var configRefreshTask: Task<Void, Never>?
    /// Periodic drain of Claude Code attention markers → native notifications.
    private var attentionTask: Task<Void, Never>?
    /// Guards against overlapping `drainAttention` runs (re-entrant restarts).
    private var attentionDraining = false

    private static let pollIntervalSeconds: TimeInterval = 60
    /// Wall-clock backstop for a single tier read. Generous — above the worst-case
    /// legitimate poll (OAuth refresh + usage GET + transient retries, ~40 s) — so it
    /// only ever trips on a genuinely wedged read, never a slow-but-progressing one. A
    /// trip throws so `isLoading` resets and the loop recovers on the next interval
    /// instead of freezing every later refresh.
    private static let pollTimeoutSeconds: TimeInterval = 60
    private static let oauthEnrichmentIntervalSeconds: TimeInterval = 300
    private static let rebuildDebounceMilliseconds: UInt64 = 300
    /// How much to stretch the poll cadence while on battery, to cut idle drain
    /// when unplugged. Restored automatically on the next tick after plugging in.
    private static let batteryPollMultiplier: Double = 2
    /// While the display/system is asleep the loop skips polling entirely and
    /// re-checks at this slow cadence; `PowerMonitor.onWake` provides immediacy,
    /// so this is only a safety net (e.g. a missed wake notification).
    private static let asleepRecheckSeconds: TimeInterval = 300
    /// How often to drain attention markers and fire notifications — low-latency
    /// "your turn" without a file watcher; cheap (a stat of a usually-empty dir).
    private static let attentionDrainSeconds: TimeInterval = 2
    /// While the poll loop isn't running (attention on, no data source), self-heal
    /// the hooks every this-many drain ticks (~60 s at the 2 s cadence).
    private static let attentionSelfHealEveryTicks = 30

    var cursorUsage: CursorUsage? { cursorReading?.value }
    var cursorError: String? { cursorReading?.error }
    var cursorLastPolledAt: Date? { cursorReading?.lastPolledAt }
    var grokUsage: GrokUsage? { grokReading?.value }
    var grokError: String? { grokReading?.error }
    var grokLastPolledAt: Date? { grokReading?.lastPolledAt }

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
        monitor.onWake = { [weak self] in
            self?.refreshNow()
            // Restart the attention watcher so markers written near wake surface
            // promptly instead of waiting out the asleep-recheck interval.
            self?.startAttentionWatcher()
        }
        self.powerMonitor = monitor
        let network = NetworkMonitor()
        network.onReconnect = { [weak self] in
            // Connectivity regained — refresh now instead of waiting out the
            // remaining poll interval. Mirrors PowerMonitor.onWake.
            self?.refreshNow()
        }
        self.networkMonitor = network
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
        attentionTask?.cancel()
    }

    func startPolling() {
        pollTask?.cancel()
        // Config bridges + the attention watcher are independent of whether a usage
        // data source is enabled (attention comes from Claude Code hooks, not the
        // meter pipeline), so they run regardless of `canPoll`.
        refreshConfigBridges()
        startAttentionWatcher()
        guard canPoll else {
            pollTask = nil
            return
        }
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
        // Only the meter poll — the attention watcher has its own lifecycle (it's
        // not tied to having a usage data source).
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called by Settings when an attention toggle flips: reconcile the installed
    /// hooks, (re)start or stop the watcher, and clean up markers when disabled.
    func attentionSettingsChanged() {
        refreshConfigBridges()
        startAttentionWatcher()
        if !AppSettings.attentionEnabled { clearAttentionEvents() }
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

    var codexIsStale: Bool {
        codexAccounts.contains {
            $0.isStale
                || ($0.usage != nil && AppGroupConfig.isSnapshotStale(lastPollAt: $0.lastPolledAt))
        }
    }

    var grokIsStale: Bool {
        AppGroupConfig.isSnapshotStale(lastPollAt: grokLastPolledAt)
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
        cursorReading = nil
    }

    func setCodexSourceEnabled(_ enabled: Bool) {
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        if enabled {
            if isActive { startPolling() }
        } else {
            pipelineGeneration += 1
            clearCodexState()
            if canPoll {
                // Claude/Cursor sources may still be enabled.
            } else {
                stopPolling()
                isLoading = false
            }
        }
    }

    func clearCodexState() {
        codexAccounts = []
    }

    func refreshCodexAccountLabels() {
        let names = AppSettings.codexAccountNames
        codexAccounts = codexAccounts.map { reading in
            let account = CodexAccount(
                home: reading.account.home,
                isImplicit: reading.account.isImplicit,
                customName: names[reading.id])
            return CodexAccountReading(account: account, state: reading.state)
        }
    }

    func setGrokSourceEnabled(_ enabled: Bool) {
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        if enabled {
            if isActive { startPolling() }
        } else {
            pipelineGeneration += 1
            clearGrokState()
            if canPoll {
                // Claude/Cursor/Codex sources may still be enabled.
            } else {
                stopPolling()
                isLoading = false
            }
        }
    }

    func clearGrokState() {
        grokReading = nil
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
        lastAccountsFetchAt = nil
        cachedAccountReadings = []
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        pipeline = AppState.makePipeline(store: store)
        if canPoll && pollTask == nil {
            // startPolling reconciles bridges + (re)starts the attention watcher.
            startPolling()
        } else {
            // Already polling, or no data source — reconcile bridges + re-evaluate the
            // attention watcher (it runs regardless of canPoll) without churning the
            // poll loop. (Avoids the double-invoke that calling startPolling too would
            // cause.)
            refreshConfigBridges()
            startAttentionWatcher()
            if !canPoll {
                stopPolling()
                isLoading = false
            }
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
            startAttentionWatcher()  // self-cancels now that isActive == false
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

    /// The single account the menu bar speaks for when showing a specific window
    /// (5h / 7d / both): the pinned account if set, else the active account (the
    /// snapshot's top-level mirror). Nil with no snapshot.
    var menuBarActiveLimits: LimitInfo? {
        guard let snap = snapshot else { return nil }
        let pinned = AppGroupConfig.menuBarAccount
        if pinned != "", pinned != "nearest",
            let acc = snap.accounts?.first(where: { $0.id == pinned })
        {
            return acc.limits
        }
        return snap.limits
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
        refreshConfigBridges()  // self-heal statusline + attention hooks each poll
        guard !isLoading else {
            refreshPending = true
            return
        }
        let configuration = PollConfiguration(generation: pipelineGeneration)
        isLoading = true
        defer {
            isLoading = false
            if refreshPending {
                refreshPending = false
                Task { await poll() }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            if configuration.claudeEnabled {
                group.addTask { await self.pollClaude(configuration: configuration) }
            }
            if configuration.cursorEnabled {
                group.addTask { await self.pollCursor(configuration: configuration) }
            }
            if configuration.codexEnabled {
                group.addTask { await self.pollCodex(configuration: configuration) }
            }
            if configuration.grokEnabled {
                group.addTask { await self.pollGrok(configuration: configuration) }
            }
        }
    }

    private func pollClaude(configuration: PollConfiguration) async {
        let pipeline = self.pipeline
        let now = Date()
        async let serviceStatusTask: Void = refreshServiceStatus(
            generation: configuration.generation)
        do {
            let result = try await Timeout.run(seconds: Self.pollTimeoutSeconds) {
                try await pipeline.poll(now: now)
            }
            await serviceStatusTask
            guard configuration.generation == pipelineGeneration, canPoll else { return }

            lastPollResult = result
            refreshClaudeCodeVersion(now: now)

            if result.isFatal {
                lastError = DiagnosticsSanitizer.sanitize(
                    result.errors.map(\.message).joined(separator: "; "))
                await notificationEngine.pollFailed()
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
                // Per-account OAuth readings (multi-account tier): fill each
                // account's plan/email/Opus/extra and cover accounts with no
                // live session. Fill-only-missing; top-level fields untouched.
                let readings = await accountReadings(now: now)
                let mergedSnap = MultiAccountOAuth.merge(readings: readings, into: snap, now: now)
                let accountsChanged = mergedSnap != snap
                snap = mergedSnap
                if !costResult.models.isEmpty || enrichment != nil || accountsChanged {
                    try? store.writeLatest(snap)
                }
                snapshot = snap
                lastPolledAt = snap.lastSuccessfulPollAt ?? Date()
                recordUsageHistory(snap, now: now)
                await notificationEngine.process(
                    snapshot: snap,
                    previous: didPollInSession ? previous : nil,
                    // Recovery diffs against the real previous even on the first poll, so
                    // a window that reset while the app was quit still fires "refueled"
                    // (escalation stays suppressed by the nil above to avoid a stale
                    // cross-window crossing).
                    recoveryBaseline: previous,
                    isStale: claudeIsStale || snap.state.isStale
                )
                didPollInSession = true
                if shouldReloadWidget(previous: previous, current: snap) {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } else {
                // No snapshot at all — not a fresh reading, so it must not count
                // toward the predictive tracker's consecutive-poll confirmation.
                await notificationEngine.pollFailed()
            }

            if let apiWarning = result.warnings.first(where: { $0.field == "claude.ai API" }) {
                lastError = apiWarning.message
            } else {
                lastError = nil
            }
        } catch {
            await serviceStatusTask
            guard configuration.generation == pipelineGeneration, canPoll else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = DiagnosticsSanitizer.sanitize(message)
            await notificationEngine.pollFailed()
        }
    }

    /// Cursor runs independently of the Claude pipeline so a Cursor failure never
    /// affects Claude state (and vice versa).
    private func pollCursor(configuration: PollConfiguration) async {
        let provider = cursorProvider
        let now = Date()
        do {
            let usage = try await Timeout.run(seconds: Self.pollTimeoutSeconds) {
                try await provider.fetchUsage(now: now)
            }
            guard configuration.generation == pipelineGeneration,
                canPoll,
                AppSettings.cursorSourceEnabled
            else { return }
            cursorReading = .current(value: usage, polledAt: Date())
        } catch {
            guard configuration.generation == pipelineGeneration,
                canPoll,
                AppSettings.cursorSourceEnabled
            else { return }
            let message = DiagnosticsSanitizer.sanitize(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            switch error {
            case CursorError.notDetected, CursorError.unauthorized, CursorError.forbidden:
                cursorReading = .failed(error: message, lastPolledAt: cursorLastPolledAt)
            default:
                if let usage = cursorUsage, let polledAt = cursorLastPolledAt {
                    cursorReading = .stale(value: usage, polledAt: polledAt, error: message)
                } else {
                    cursorReading = .failed(error: message, lastPolledAt: cursorLastPolledAt)
                }
            }
        }
    }

    /// Codex runs independently of Claude and Cursor so failures never affect
    /// Claude state, menu-bar severity, widget data, or notifications.
    private func pollCodex(configuration: PollConfiguration) async {
        let now = Date()
        let previous = Dictionary(uniqueKeysWithValues: codexAccounts.map { ($0.id, $0) })
        let accounts = configuration.codexAccounts
        var readings: [CodexAccountReading] = []
        for batch in accounts.chunked(into: 3) {
            let results = await withTaskGroup(of: CodexAccountReading.self) { group in
                for account in batch {
                    let prior = previous[account.id]
                    group.addTask {
                        let provider = CodexUsageProvider(codexHome: account.home)
                        do {
                            let usage = try await Timeout.run(seconds: Self.pollTimeoutSeconds) {
                                try await provider.fetchUsage(
                                    mode: configuration.codexMode, now: now)
                            }
                            return CodexAccountReading(
                                account: account, state: .current(value: usage, polledAt: Date()))
                        } catch {
                            let message = DiagnosticsSanitizer.sanitize(
                                (error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription)
                            if let usage = prior?.usage, let polledAt = prior?.lastPolledAt {
                                return CodexAccountReading(
                                    account: account,
                                    state: .stale(
                                        value: usage, polledAt: polledAt, error: message))
                            }
                            return CodexAccountReading(
                                account: account,
                                state: .failed(error: message, lastPolledAt: nil))
                        }
                    }
                }
                var batchReadings: [CodexAccountReading] = []
                for await reading in group {
                    batchReadings.append(reading)
                }
                return batchReadings
            }
            readings.append(contentsOf: results)
        }
        guard configuration.generation == pipelineGeneration,
            canPoll,
            AppSettings.codexSourceEnabled
        else { return }
        let byID = Dictionary(uniqueKeysWithValues: readings.map { ($0.id, $0) })
        codexAccounts = accounts.compactMap { byID[$0.id] }
    }

    /// Grok runs independently of Claude, Cursor, and Codex so failures never
    /// affect Claude state, menu-bar severity, widget data, or notifications.
    private func pollGrok(configuration: PollConfiguration) async {
        let provider = grokProvider
        let now = Date()
        do {
            let usage = try await Timeout.run(seconds: Self.pollTimeoutSeconds) {
                try await provider.fetchUsage(now: now)
            }
            guard configuration.generation == pipelineGeneration,
                canPoll,
                AppSettings.grokSourceEnabled
            else { return }
            grokReading = .current(value: usage, polledAt: Date())
        } catch {
            guard configuration.generation == pipelineGeneration,
                canPoll,
                AppSettings.grokSourceEnabled
            else { return }
            let message = DiagnosticsSanitizer.sanitize(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            if let usage = grokUsage, let polledAt = grokLastPolledAt {
                grokReading = .stale(value: usage, polledAt: polledAt, error: message)
            } else {
                grokReading = .failed(error: message, lastPolledAt: grokLastPolledAt)
            }
        }
    }

    /// Samples each account's windows into the persisted usage history (fire-and-forget
    /// onto the history actor). Per-account so multi-account users keep distinct series;
    /// a lone single-account snapshot is keyed `claude`, matching the bridge default.
    private func recordUsageHistory(_ snap: ClaudeUsageSnapshot, now: Date) {
        let accounts: [(key: String, limits: LimitInfo)]
        if let accs = snap.accounts, !accs.isEmpty {
            accounts = accs.map { ($0.id, $0.limits) }
        } else {
            accounts = [("claude", snap.limits)]
        }
        let samples = accounts.flatMap {
            Self.usageHistorySamples(accountKey: $0.key, limits: $0.limits, now: now)
        }
        guard !samples.isEmpty else { return }
        let store = usageHistory
        Task.detached { for sample in samples { await store.record(sample) } }
    }

    /// Builds history samples for an account's resolved windows. Uses `resolved(asOf:)`
    /// so an expired window records 0% rather than a stale reading.
    static func usageHistorySamples(accountKey: String, limits: LimitInfo, now: Date)
        -> [UsageHistorySample]
    {
        var out: [UsageHistorySample] = []
        func add(_ window: UsageHistoryWindow, _ raw: LimitWindow?) {
            guard let resolved = raw?.resolved(asOf: now), let used = resolved.percentUsed else {
                return
            }
            out.append(
                UsageHistorySample(
                    accountKey: accountKey, window: window, sampledAt: now,
                    usedPercent: used, resetsAt: resolved.resetsAt))
        }
        add(.session, limits.currentSession)
        add(.weekly, limits.currentWeekAllModels)
        add(.weeklyOpus, limits.currentWeekOpus)
        return out
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

    /// Per-account OAuth readings for every discovered config dir (multi-account
    /// tier). Interval-gated like the single-slot enrichment; the fetch itself
    /// runs off-main (inside `Timeout.run`'s detached task). Returns cached
    /// readings between refreshes so every poll can re-merge.
    ///
    /// Gated on `oauthMode == "auto"` (the user explicitly connected the Claude
    /// Code token), not just the source toggle: reading another app's Keychain
    /// items surfaces the macOS ACL password prompt once per entry, which must
    /// never ambush a statusline-only user. Manual mode is excluded too — its
    /// app-owned token deliberately avoids Claude Code's Keychain entries.
    private func accountReadings(now: Date) async -> [OAuthAccountReading] {
        guard AppSettings.oauthSourceEnabled,
            UserDefaults.standard.string(forKey: AppGroupConfig.oauthModeKey) == "auto"
        else { return [] }
        if let lastAccountsFetchAt,
            now.timeIntervalSince(lastAccountsFetchAt) < Self.oauthEnrichmentIntervalSeconds
        {
            return cachedAccountReadings
        }
        lastAccountsFetchAt = now
        let configuredDirs = AppGroupConfig.configuredConfigDirs
        let disabledKeys = Set(AppGroupConfig.disabledAccountKeys)
        let thresholds = AppGroupConfig.currentThresholds()
        let readings =
            (try? await Timeout.run(seconds: 30) { () async -> [OAuthAccountReading] in
                let accounts = ConfigDirDiscovery.discover(
                    configuredDirs: configuredDirs, disabledKeys: disabledKeys)
                return await MultiAccountOAuth.fetchAll(
                    accounts: accounts,
                    home: FileManager.default.homeDirectoryForCurrentUser,
                    thresholds: thresholds,
                    transport: ProviderHTTPClient.shared,
                    credentialsLoader: { path, isDefault in
                        OAuthKeychain.loadResult(configDirPath: path, isDefault: isDefault)
                    },
                    now: now)
            }) ?? []
        if !readings.isEmpty { cachedAccountReadings = readings }
        return cachedAccountReadings
    }

    private static func apply(
        _ e: OAuthPipeline.OAuthEnrichment, to snap: inout ClaudeUsageSnapshot
    ) {
        if let opus = e.opus { snap.limits.currentWeekOpus = opus }
        if let scoped = e.scopedWeekly { snap.limits.scopedWeekly = scoped }
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
    /// Refreshes the latest-known Claude Code version (npm, 6 h cached). Fire-and-
    /// forget: the network call runs off the main actor and only the published
    /// string update lands back on it. Cheap to call each poll thanks to the cache.
    private func refreshClaudeCodeVersion(now: Date) {
        Task { [weak self] in
            let latest = await ClaudeCodeVersionCheck.latestVersion(now: now)
            guard let self, let latest else { return }
            self.latestClaudeCodeVersion = latest
        }
    }

    private static func scanCostModels(now: Date) async -> CostUsageResult {
        await Task.detached(priority: .utility) {
            // Live per-model prices from models.dev (24 h disk cache, static family
            // rates as the offline fallback), fetched off the poll thread.
            let catalog = await ModelsDevPricing.loadCatalog(now: now)
            let accounts = ConfigDirDiscovery.discover(
                configuredDirs: AppGroupConfig.configuredConfigDirs,
                disabledKeys: Set(AppGroupConfig.disabledAccountKeys))
            let paths =
                accounts.isEmpty
                ? [JournalReader.defaultProjectsPath] : accounts.map(\.projectsPath)
            let pricing = ModelPricing.current.withCatalog(catalog)
            return CostUsageScanner(projectsPaths: paths, pricing: pricing).scan(
                daysBack: 7, now: now)
        }.value
    }

    /// Scans local transcripts for the 7×24 activity heatmap (off-main). Called
    /// when the user opens the heatmap; refreshes the existing result in place.
    /// The task handle is kept so closing the heatmap cancels a scan mid-flight
    /// (the scanner checks `Task.isCancelled` per file); the generation guard
    /// keeps a cancelled scan's completion from clobbering a newer load's state.
    private var activityHeatmapTask: Task<Void, Never>?
    private var activityHeatmapGeneration = 0

    func loadActivityHeatmap() {
        guard !activityHeatmapLoading else { return }
        activityHeatmapLoading = true
        activityHeatmapGeneration += 1
        let generation = activityHeatmapGeneration
        let now = Date()
        activityHeatmapTask = Task.detached(priority: .userInitiated) { [weak self] in
            let accounts = ConfigDirDiscovery.discover(
                configuredDirs: AppGroupConfig.configuredConfigDirs,
                disabledKeys: Set(AppGroupConfig.disabledAccountKeys))
            let paths =
                accounts.isEmpty
                ? [JournalReader.defaultProjectsPath] : accounts.map(\.projectsPath)
            let result = ActivityScanner(projectsPaths: paths).scan(daysBack: 30, now: now)
            let cancelled = Task.isCancelled
            await MainActor.run { [weak self] in
                guard let self, self.activityHeatmapGeneration == generation else { return }
                if !cancelled { self.activityHeatmap = result }
                self.activityHeatmapLoading = false
            }
        }
    }

    /// Cancels an in-flight heatmap scan (the user closed the heatmap or the
    /// popover). The cut-short grid is discarded, never published.
    func cancelActivityHeatmapLoad() {
        activityHeatmapTask?.cancel()
        activityHeatmapTask = nil
        activityHeatmapGeneration += 1
        activityHeatmapLoading = false
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

    /// Installs/self-heals the statusline bridge (when its source is enabled) AND
    /// reconciles the attention hooks across every discovered config dir — in ONE
    /// serialized off-main task. Running them sequentially over a single discovery
    /// means the two never race on the same `settings.json` (separate concurrent
    /// writers would clobber each other). Idempotent; coalesces rapid re-invocations
    /// by cancelling the prior in-flight task.
    private func refreshConfigBridges() {
        let statuslineOn = AppSettings.statuslineSourceEnabled
        let events = AppSettings.enabledAttentionEvents
        let store = store
        let configuredDirs = AppGroupConfig.configuredConfigDirs
        let disabledKeys = Set(AppGroupConfig.disabledAccountKeys)
        let previous = configRefreshTask
        previous?.cancel()
        configRefreshTask = Task.detached(priority: .utility) {
            // Wait for any prior install to finish first — cancellation is cooperative
            // and the synchronous install can't be interrupted mid-write, so this
            // guarantees two installs never write the same settings.json concurrently.
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            let accounts = ConfigDirDiscovery.discover(
                configuredDirs: configuredDirs, disabledKeys: disabledKeys)
            guard !Task.isCancelled else { return }
            let dirs = accounts.map(\.configDir)
            do {
                if statuslineOn {
                    try StatuslineBridge.install(configDirs: dirs)
                }
                // Reconcile hooks on enabled accounts (install enabled events, remove
                // the rest). Disabled accounts keep their snippet — like the
                // statusline bridge — and are filtered on the read path (`drain`).
                try HookBridge.install(configDirs: dirs, events: events)
            } catch {
                let message =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                try? store.writeLastError(
                    LastErrorRecord(message: DiagnosticsSanitizer.sanitize(message)))
            }
        }
    }

    // MARK: - Attention (Claude Code hooks)

    /// Drains attention markers and fires a native notification per event, on its
    /// own energy-aware cadence (independent of the meter poll): backs off to the
    /// asleep recheck while the display is asleep, and stretches on battery — macOS
    /// owns sound, Focus/DND, and Notification-Center history.
    private func startAttentionWatcher() {
        attentionTask?.cancel()
        guard isActive, AppSettings.attentionEnabled else {
            attentionTask = nil
            return
        }
        attentionTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { break }
                if self.powerMonitor?.isDisplayAsleep == true {
                    // Asleep: back off (PowerMonitor.onWake restarts us for an
                    // immediate drain), don't spin a 2 s timer overnight.
                    try? await Task.sleep(for: .seconds(Self.asleepRecheckSeconds))
                    continue
                }
                await self.drainAttention()
                tick += 1
                // Self-heal the hooks periodically when the poll loop isn't running to
                // do it (attention enabled but no usage data source) — so a dropped
                // hook still recovers without a relaunch.
                if tick % Self.attentionSelfHealEveryTicks == 0, !self.canPoll {
                    self.refreshConfigBridges()
                }
                let interval =
                    self.powerMonitor?.isOnBattery == true
                    ? Self.attentionDrainSeconds * Self.batteryPollMultiplier
                    : Self.attentionDrainSeconds
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func drainAttention() async {
        // Guard against overlapping drains (e.g. an onWake/toggle restart while a
        // prior drain is mid-flight) — they could double-emit the same marker.
        guard !attentionDraining else { return }
        attentionDraining = true
        defer { attentionDraining = false }

        let now = Date()
        let disabled = Set(AppGroupConfig.disabledAccountKeys)
        let events = await Task.detached(priority: .utility) {
            SessionEventStore.drain(disabledAccountKeys: disabled, now: now)
        }.value
        guard !events.isEmpty else { return }

        let engine = notificationEngine
        let enabled = AppSettings.enabledAttentionEvents
        var sawLimitBlock = false
        for event in events where enabled.contains(event.kind.rawValue) {
            // A StopFailure only alerts when it's a real limit/billing block — auth,
            // server, and invalid-request failures are noise for a rate-limit meter.
            if event.kind == .stopFailure {
                guard event.isLimitBlock else { continue }
                sawLimitBlock = true
            }
            let account = Self.friendlyAccountName(event.accountKey)
            // Fire-and-forget: a slow/wedged notification call must never stall the
            // drain loop.
            Task { await engine.postAttention(event: event, accountLabel: account) }
        }
        // A limit block is ground truth that usage maxed out — re-poll now so the
        // meter reflects it immediately instead of waiting for the next interval.
        if sawLimitBlock { refreshNow() }
    }

    /// Clears leftover markers when attention is disabled.
    private func clearAttentionEvents() {
        Task.detached(priority: .utility) { SessionEventStore.clearAll() }
    }

    /// The display name for an account key — the user's override, else a prettified
    /// label — matching how the popover labels accounts (which strips the `claude-`
    /// prefix / maps `claude` → "default" via `ConfigDirDiscovery.label`).
    static func friendlyAccountName(_ key: String) -> String {
        AppGroupConfig.accountName(forKey: key)
            ?? ConfigDirDiscovery.label(forKey: key).friendlyAccountLabel
    }
}

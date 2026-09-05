import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI
import WidgetKit

struct ConfigBridgeRefreshRequest: Sendable {
    let statuslineEnabled: Bool
    let attentionEvents: Set<String>
    let configuredDirs: [String]
    let disabledAccountKeys: Set<String>
    let store: SnapshotStore
}

typealias ConfigBridgeRefreshOperation =
    @Sendable (ConfigBridgeRefreshRequest) async -> Void
typealias CodexUsageFetchOperation =
    @Sendable (CodexAccount, CodexSourceMode, Date) async throws -> CodexUsage
typealias AttentionEventDrainOperation =
    @Sendable (Set<String>, Date) async -> [SessionEvent]
typealias MainMeterPublicationOperation =
    @Sendable (MainMeterReading?, SnapshotStore) throws -> Void

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: ClaudeUsageSnapshot? = nil
    @Published var lastPollResult: ParseResult? = nil
    @Published var isLoading = false
    @Published private(set) var claudeIsLoading = false
    @Published private(set) var codexIsLoading = false
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
    let notificationEngine: NotificationEngine
    private let store: SnapshotStore
    private let codexReadingStore: CodexReadingStore
    /// Test meters keep pause/resume writes out of the installed app's settings.
    private let activationDefaults: UserDefaults
    private let ephemeralDefaultsSuiteName: String?
    /// Present only for the dependency-injected initializer. Keeping each test in
    /// its own directory prevents parallel runs from sharing `current.json`.
    private let ephemeralStoreDirectory: URL?
    /// Tests exercise polling without changing Claude Code settings or consuming
    /// real attention markers.
    private let systemIntegrationEnabled: Bool
    private let appUpdater: AppUpdater
    /// Advisory service status is intentionally detached from the authoritative
    /// usage poll. A slow Statuspage request must never delay fresh quota data.
    private let serviceStatusFetcher: @Sendable () async -> ServiceStatus?
    /// Auxiliary OAuth-only fields have their own lifecycle because a fresh
    /// statusline snapshot short-circuits the main OAuth fallback tier.
    private let oauthEnrichmentFetcher:
        @Sendable (Date) async -> OAuthPipeline.OAuthEnrichmentFetchResult
    private let costUsageScanner: @Sendable (Date, PollConfiguration) async -> CostUsageResult
    /// Test seam that can hold a completed provider group before its cycle releases
    /// the shared loading state. Production polling does not install a barrier.
    private let pollCompletionBarrier: (@Sendable () async -> Void)?
    private let configBridgeRefreshOperation: ConfigBridgeRefreshOperation
    private let attentionEventDrainOperation: AttentionEventDrainOperation
    private let mainMeterPublicationOperation: MainMeterPublicationOperation
    private var serviceStatusRefreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Identifies the cycle that owns the aggregate and provider loading flags.
    /// A cancelled cycle can resume later, but it cannot clear a newer cycle's UI.
    private var activePollCycleID: UInt64?
    private var nextPollCycleID: UInt64 = 0
    private var rebuildDebounceTask: Task<Void, Never>?
    private var pipelineGeneration = 0
    private var refreshPending = false
    /// Intent of a refresh that arrived mid-poll. `.interactive` sticks until the
    /// deferred poll consumes it — otherwise opening the popover during a poll
    /// (likely, at a 60 s cadence) would silently downgrade to `.background` and
    /// serve cache, which is the exact case the bypass exists for.
    private var pendingRefreshKind: RefreshKind = .background
    /// Identity last processed by quota notifications. A provider/account switch
    /// starts a new baseline instead of comparing unrelated meters.
    private var notificationIdentity: String?
    private var lastNotificationReading: MainMeterReading?
    private var publishedMainMeterReading: MainMeterReading?
    /// A cold launch may recover from a persisted same-account baseline. Explicit
    /// provider/account switches suppress that recovery on their first observation.
    private var allowsPersistedNotificationRecovery = true
    private var powerMonitor: PowerMonitor?
    private var networkMonitor: NetworkMonitor?
    private var memoryPressureMonitor: MemoryPressureMonitor?
    private var lastOAuthEnrichmentAttemptAt: Date?
    @Published private var oauthEnrichmentReading: ReadingState<OAuthPipeline.OAuthEnrichment>?
    private var oauthEnrichmentAccountKey: String?
    private var lastAccountsFetchAt: Date?
    private var cachedAccountReadings: [OAuthAccountReading] = []
    @Published private(set) var accountOAuthFailures:
        [String: MultiAccountOAuth.AccountFetchFailure] = [:]
    /// At most one statusline/hook reconciliation runs at a time. Repeated requests
    /// set one rerun bit, so a wedged synchronous filesystem call cannot build an
    /// unbounded chain of detached waiters.
    private var configRefreshTask: Task<Void, Never>?
    private var configRefreshRerunRequested = false
    private var configRefreshID: UInt64 = 0
    private(set) var configRefreshOperationCount = 0
    /// Periodic drain of Claude Code attention markers → native notifications.
    private var attentionTask: Task<Void, Never>?
    /// Guards against overlapping `drainAttention` runs (re-entrant restarts).
    private var attentionDraining = false
    /// First-run onboarding blocks all polling and bridge work until the user
    /// chooses Get Started. Existing-user evidence sets this before startup work.
    private var onboardingIsComplete: Bool

    private static let pollIntervalSeconds: TimeInterval = 60
    /// Wall-clock backstop for a single tier read. Generous — above the worst-case
    /// legitimate poll (OAuth refresh + usage GET + transient retries, ~40 s) — so it
    /// only ever trips on a genuinely wedged read, never a slow-but-progressing one. A
    /// trip throws so `isLoading` resets and the loop recovers on the next interval
    /// instead of freezing every later refresh.
    private static let pollTimeoutSeconds: TimeInterval = 60
    /// Transcript reads are advisory. Keep them below the main poll deadline so a
    /// wedged filesystem cannot stop fresh quota data from being published.
    private static let transcriptScanTimeoutSeconds: TimeInterval = 30
    /// A stuck transcript read must not consume the capacity used by provider
    /// requests. Two slots allow the cost and activity scans to overlap once.
    private static let transcriptScanTimeoutBudget = Timeout.TaskBudget(limit: 2)
    /// Isolate cancellation-ignoring Codex processes from other providers. Two
    /// batches can remain abandoned; later cycles then fail fast until they exit.
    private static let codexPollTimeoutBudget = Timeout.TaskBudget(limit: 6)
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
    var oauthEnrichmentIsStale: Bool {
        snapshot?.source.cliPath != "api.anthropic.com"
            && oauthEnrichmentAccountKey == (snapshot?.activeAccountID ?? "claude")
            && oauthEnrichmentReading?.isStale == true
    }
    var oauthEnrichmentError: String? {
        guard snapshot?.source.cliPath != "api.anthropic.com" else { return nil }
        return oauthEnrichmentReading?.error
    }
    var oauthEnrichmentLastPolledAt: Date? {
        guard snapshot?.source.cliPath != "api.anthropic.com" else { return nil }
        return oauthEnrichmentReading?.lastPolledAt
    }
    /// Credential problem on the OAuth tier, when there is one the user should
    /// see. Only surfaced while OAuth is actually configured — the tier is
    /// skipped silently otherwise, and a warning would be noise.
    var oauthCredentialIssue: OAuthCredentialIssue? {
        guard AppSettings.oauthSourceEnabled,
            let attempts = lastPollResult?.sourceAttempts
        else { return nil }
        return OAuthCredentialIssue.from(sourceAttempts: attempts)
    }

    /// When an active OAuth 429 backoff lifts, for the `.rateLimited` notice's
    /// countdown. `nil` whenever we aren't throttled.
    var oauthRetryAt: Date? { OAuthPipeline.rateLimitedUntil() }

    /// Per-account usage rows for accounts other than the active one (for the
    /// popover's multi-account section). Empty for the common single-account case.
    var otherAccounts: [AccountUsage] {
        snapshot?.accounts?.filter { !$0.isActive } ?? []
    }

    /// Label of the account currently mirrored into the menu bar / top-level fields.
    var activeAccountLabel: String? {
        snapshot?.accounts?.first(where: { $0.isActive })?.label
    }

    var mainMeterProvider: MainMeterProvider {
        AppGroupConfig.resolvedMainMeterProvider(shared: nil)
    }

    private struct MainMeterSourceState {
        let readings: [MainMeterReading]
        let selected: MainMeterReading?
        let isLoading: Bool
        let error: String?
    }

    private var mainMeterSourceState: MainMeterSourceState {
        let provider = mainMeterProvider
        switch provider {
        case .claude:
            guard AppSettings.hasClaudeSource else {
                return MainMeterSourceState(
                    readings: [], selected: nil, isLoading: claudeIsLoading,
                    error: "Claude is not enabled in Data settings.")
            }
            let readings = snapshot.map(Self.claudeMainMeterReadings(from:)) ?? []
            let selected = Self.selectedMainMeterReading(readings, provider: provider)
            let error: String?
            if selected == nil {
                error = lastError ?? "The selected Claude account has no usage reading."
            } else {
                error = lastError
            }
            return MainMeterSourceState(
                readings: readings,
                selected: selected,
                isLoading: claudeIsLoading,
                error: error)
        case .codex:
            guard AppSettings.codexSourceEnabled else {
                return MainMeterSourceState(
                    readings: [], selected: nil, isLoading: codexIsLoading,
                    error: "Codex is not enabled in Data settings.")
            }
            let readings = codexAccounts.compactMap(Self.codexMainMeterReading)
            let selected = Self.selectedMainMeterReading(readings, provider: provider)
            let error: String?
            if case .account(let key) = AppGroupConfig.mainMeterAccountSelection(
                provider: .codex)
            {
                if let lifecycle = codexAccounts.first(where: { $0.id == key }) {
                    error =
                        lifecycle.usage == nil
                        ? lifecycle.error ?? "The selected Codex account has no usage reading."
                        : lifecycle.error
                } else {
                    error = "The selected Codex account is no longer configured."
                }
            } else {
                error =
                    codexAccounts.compactMap(\.error).first
                    ?? (selected == nil ? "Codex has no usage reading." : nil)
            }
            return MainMeterSourceState(
                readings: readings,
                selected: selected,
                isLoading: codexIsLoading,
                error: error)
        }
    }

    /// All usable readings for the selected provider. Ordering is stable; the
    /// selection policy chooses the nearest or explicitly pinned account.
    var mainMeterReadings: [MainMeterReading] { mainMeterSourceState.readings }

    /// Reading that owns the hero, widget, header timestamp, and specific-window
    /// menu-bar values. A pin wins. Otherwise the account nearest its limit owns
    /// every primary surface.
    var mainMeterReading: MainMeterReading? { mainMeterSourceState.selected }

    /// Limit sets considered by nearest-window menu-bar policy. A provider-specific
    /// account pin narrows the set; otherwise every selected-provider account counts.
    var mainMeterLimitSets: [LimitInfo] {
        MainMeterPolicy.considered(
            mainMeterReadings,
            pinnedAccountID: Self.pinnedAccountID(for: mainMeterProvider)
        ).map(\.limits)
    }

    var mainMeterSeverity: UsageSeverity {
        let thresholds = Self.currentThresholds()
        let now = Date()
        return mainMeterLimitSets.reduce(.unknown) { result, limits in
            limits.bindingWindows.reduce(result) { current, descriptor in
                UsageSeverity.highest(
                    current,
                    thresholds.severity(
                        for: descriptor.window.resolved(asOf: now).percentUsed))
            }
        }
    }

    var mainMeterIsStale: Bool {
        guard let reading = mainMeterReading else { return false }
        return reading.sourceMarkedStale
            || AppGroupConfig.isSnapshotStale(lastPollAt: reading.observedAt)
    }

    var mainMeterLastSuccessfulAt: Date? { mainMeterReading?.observedAt }

    var mainMeterIsLoading: Bool { mainMeterSourceState.isLoading }

    var mainMeterError: String? { mainMeterSourceState.error }

    nonisolated static func startupMainMeterTransition(
        previousPublished: MainMeterReading?,
        current: MainMeterReading?
    ) -> (bumpRevision: Bool, reloadWidget: Bool, allowsPersistedRecovery: Bool) {
        (
            bumpRevision: MainMeterPolicy.shouldBumpSelectionRevision(
                previous: previousPublished,
                current: current,
                configurationChanged: false),
            reloadWidget: MainMeterPolicy.shouldReloadWidget(
                previous: previousPublished,
                current: current),
            allowsPersistedRecovery: current != nil
                && previousPublished?.stableIdentity == current?.stableIdentity
        )
    }

    func mainMeterSelectionChanged() {
        notificationEngine.pollFailed()
        finishMainMeterSelectionChange()
    }

    private func finishMainMeterSelectionChange() {
        AppGroupConfig.bumpMainMeterRevision()
        notificationIdentity = nil
        allowsPersistedNotificationRecovery = false
        publishMainMeterReading()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func mainMeterMetadataChanged(provider: MainMeterProvider) {
        guard mainMeterProvider == provider else { return }
        notificationEngine.pollFailed()
        AppGroupConfig.bumpMainMeterRevision()
        publishMainMeterReading()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// One-shot cleanup of `usage-history.jsonl`, the per-account time series the
    /// app used to record every poll. Nothing ever read it back, so the collector
    /// was removed — this stops a few hundred KB of orphaned data sitting in
    /// Application Support forever. No-op once it's gone.
    private static func removeLegacyUsageHistory() {
        Task.detached(priority: .background) {
            guard
                let base = try? FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                    create: false)
            else { return }
            try? FileManager.default.removeItem(
                at:
                    base
                    .appendingPathComponent("ClaudeMeter", isDirectory: true)
                    .appendingPathComponent("usage-history.jsonl"))
        }
    }

    private static func claudeMainMeterReadings(
        from snapshot: ClaudeUsageSnapshot
    ) -> [MainMeterReading] {
        let observedAt = snapshot.lastSuccessfulPollAt ?? snapshot.createdAt
        if let accounts = snapshot.accounts, !accounts.isEmpty {
            let disabled = Set(AppGroupConfig.disabledAccountKeys)
            return accounts.filter { !disabled.contains($0.id) }.sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }.map { account in
                MainMeterReading(
                    provider: .claude,
                    accountID: account.id,
                    accountLabel: AppGroupConfig.accountName(forKey: account.id)
                        ?? account.label.friendlyAccountLabel,
                    plan: AppGroupConfig.accountPlan(forKey: account.id)
                        ?? (account.isActive ? snapshot.account?.plan : account.account?.plan),
                    limits: account.isActive ? snapshot.limits : account.limits,
                    observedAt: account.lastSuccessfulPollAt ?? observedAt,
                    selectionRevision: AppGroupConfig.mainMeterRevision(shared: nil),
                    sourceMarkedStale: snapshot.state.isStale)
            }
        }
        return [
            MainMeterReading(
                provider: .claude,
                accountID: StatuslineBridge.defaultAccountKey,
                accountLabel: AppGroupConfig.accountName(forKey: StatuslineBridge.defaultAccountKey)
                    ?? "Claude",
                plan: AppGroupConfig.accountPlan(forKey: StatuslineBridge.defaultAccountKey)
                    ?? snapshot.account?.plan,
                limits: snapshot.limits,
                observedAt: observedAt,
                selectionRevision: AppGroupConfig.mainMeterRevision(shared: nil),
                sourceMarkedStale: snapshot.state.isStale)
        ]
    }

    nonisolated static func codexMainMeterReading(
        _ reading: CodexAccountReading
    ) -> MainMeterReading? {
        guard let usage = reading.usage, let observedAt = reading.lastSuccessfulAt else {
            return nil
        }
        let windows = classifiedCodexWindows(usage)
        return MainMeterReading(
            provider: .codex,
            accountID: reading.id,
            accountLabel: reading.account.displayName,
            plan: usage.displayPlanName,
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: windows.session?.usedPercent,
                    resetsAt: windows.session?.resetAt),
                currentWeekAllModels: LimitWindow(
                    percentUsed: windows.weekly?.usedPercent,
                    resetsAt: windows.weekly?.resetAt)),
            sessionLabel: windows.session?.displayLabel ?? "5h",
            weeklyLabel: windows.weekly?.displayLabel ?? "7d",
            observedAt: observedAt,
            selectionRevision: AppGroupConfig.mainMeterRevision(shared: nil))
    }

    private nonisolated static func classifiedCodexWindows(_ usage: CodexUsage) -> (
        session: CodexLimitWindow?, weekly: CodexLimitWindow?
    ) {
        var session: CodexLimitWindow?
        var weekly: CodexLimitWindow?
        for window in [usage.primaryWindow, usage.secondaryWindow].compactMap({ $0 }) {
            let isWeekly: Bool
            if let duration = window.durationSeconds {
                isWeekly = duration > 24 * 60 * 60
            } else {
                isWeekly = window.kind == .secondary
            }
            if isWeekly {
                if weekly == nil || (window.usedPercent ?? -1) > (weekly?.usedPercent ?? -1) {
                    weekly = window
                }
            } else if session == nil || (window.usedPercent ?? -1) > (session?.usedPercent ?? -1) {
                session = window
            }
        }
        return (session, weekly)
    }

    private static func selectedMainMeterReading(
        _ readings: [MainMeterReading],
        provider: MainMeterProvider
    ) -> MainMeterReading? {
        MainMeterPolicy.primary(
            from: readings,
            pinnedAccountID: pinnedAccountID(for: provider))
    }

    private static func pinnedAccountID(for provider: MainMeterProvider) -> String? {
        if case .account(let key) = AppGroupConfig.mainMeterAccountSelection(provider: provider) {
            return key
        }
        return nil
    }

    private func processMainMeterObservation(
        _ reading: MainMeterReading,
        previous: MainMeterReading?,
        isStale: Bool,
        generation: Int
    ) async {
        guard
            Self.notificationTargetMatches(
                expected: reading,
                expectedGeneration: generation,
                current: mainMeterReading,
                currentGeneration: pipelineGeneration),
            canPoll
        else { return }
        let notificationLease = notificationEngine.quotaLease()
        let baselines = NotificationPolicy.mainMeterBaselines(
            reading: reading,
            previous: previous,
            notificationIdentity: notificationIdentity,
            allowsPersistedRecovery: allowsPersistedNotificationRecovery)
        await notificationEngine.process(
            reading: reading,
            previous: baselines.escalation,
            recoveryBaseline: baselines.recovery,
            isStale: isStale,
            expectedRevision: notificationLease)
        guard
            Self.notificationTargetMatches(
                expected: reading,
                expectedGeneration: generation,
                current: mainMeterReading,
                currentGeneration: pipelineGeneration),
            canPoll
        else { return }
        guard !isStale else { return }
        notificationIdentity = reading.stableIdentity
        lastNotificationReading = reading
        allowsPersistedNotificationRecovery = true
    }

    nonisolated static func notificationTargetMatches(
        expected: MainMeterReading,
        expectedGeneration: Int,
        current: MainMeterReading?,
        currentGeneration: Int
    ) -> Bool {
        expectedGeneration == currentGeneration
            && current?.stableIdentity == expected.stableIdentity
            && current?.selectionRevision == expected.selectionRevision
    }

    private func publishMainMeterReading() {
        let reading = mainMeterReading
        do {
            try mainMeterPublicationOperation(reading, store)
            publishedMainMeterReading = reading
        } catch {
            // The main provider stores remain authoritative. Widget publication is
            // best-effort and must not change poll lifecycle or user-facing errors.
        }
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
        OAuthPipeline.enableRateLimitPersistence()
        UserDefaults.standard.register(defaults: [
            AppSettings.statuslineSourceEnabledKey: true,
            AppSettings.isActiveKey: true,
        ])
        self.onboardingIsComplete = UserDefaults.standard.bool(
            forKey: "hasCompletedOnboarding")
        AppGroupConfig.syncDisplaySettings()
        AppState.removeLegacyUsageHistory()
        let store = AppState.makeStore()
        self.store = store
        let codexReadingStore = CodexReadingStore()
        self.codexReadingStore = codexReadingStore
        self.activationDefaults = .standard
        self.ephemeralDefaultsSuiteName = nil
        self.ephemeralStoreDirectory = nil
        self.systemIntegrationEnabled = true
        self.notificationEngine = NotificationEngine()
        self.isActive = AppSettings.isActive
        self.hasEnabledDataSource = AppSettings.hasEnabledDataSource
        let appUpdater = AppUpdater(startingUpdater: true)
        self.appUpdater = appUpdater
        self.serviceStatusFetcher = { await AnthropicStatusClient().fetch() }
        self.oauthEnrichmentFetcher = { now in
            await OAuthPipeline.fetchEnrichmentResult(now: now)
        }
        self.costUsageScanner = { now, configuration in
            await AppState.scanCostModels(now: now, configuration: configuration)
        }
        self.pollCompletionBarrier = nil
        self.configBridgeRefreshOperation = { request in
            AppState.performConfigBridgeRefresh(request)
        }
        self.attentionEventDrainOperation = { disabledAccountKeys, now in
            await Task.detached(priority: .utility) {
                SessionEventStore.drain(
                    disabledAccountKeys: disabledAccountKeys, now: now)
            }.value
        }
        self.mainMeterPublicationOperation = { reading, store in
            try MainMeterPublication.replace(reading, in: store)
        }
        self.pipeline = AppState.makePipeline(store: store)
        // Self is fully initialized from here on.
        self.snapshot = try? store.readLatest()
        self.lastPolledAt = snapshot?.lastSuccessfulPollAt
        if AppSettings.codexSourceEnabled {
            self.codexAccounts = codexReadingStore.restore(accounts: AppSettings.codexAccounts())
        }
        if snapshot == nil, let record = try? store.readLastError() {
            self.lastError = record.message
        }
        let previousPublishedReading = try? store.readMainMeter()
        publishedMainMeterReading = previousPublishedReading
        lastNotificationReading = previousPublishedReading
        var currentReading = mainMeterReading
        let startupTransition = Self.startupMainMeterTransition(
            previousPublished: previousPublishedReading,
            current: currentReading)
        if startupTransition.bumpRevision {
            AppGroupConfig.bumpMainMeterRevision()
            currentReading = mainMeterReading
        }
        allowsPersistedNotificationRecovery = startupTransition.allowsPersistedRecovery
        publishMainMeterReading()
        if startupTransition.reloadWidget
            || MainMeterPolicy.shouldReloadWidget(
                previous: previousPublishedReading,
                current: currentReading)
        {
            WidgetCenter.shared.reloadAllTimelines()
        }
        appUpdater.appState = self
        if !onboardingIsComplete, hasExistingUserEvidence {
            onboardingIsComplete = true
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }
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
        let memoryPressure = MemoryPressureMonitor()
        memoryPressure.start()
        self.memoryPressureMonitor = memoryPressure
        if onboardingIsComplete {
            startPolling()
            Task { await notificationEngine.requestAuthorizationIfNeeded() }
        }
    }

    init(
        pipeline: any ClaudeMeterPipeline,
        initialSnapshot: ClaudeUsageSnapshot? = nil,
        serviceStatusFetcher: @escaping @Sendable () async -> ServiceStatus? = { nil },
        oauthEnrichmentFetcher:
            @escaping @Sendable (Date) async ->
            OAuthPipeline.OAuthEnrichmentFetchResult = { _ in .unavailable(.notConnected) },
        costUsageScanner: @escaping @Sendable (Date, PollConfiguration) async -> CostUsageResult = {
            _, _ in .empty
        },
        codexReadingStore: CodexReadingStore? = nil,
        notificationEngine: NotificationEngine = NotificationEngine(),
        pollCompletionBarrier: (@Sendable () async -> Void)? = nil,
        systemIntegrationEnabled: Bool = false,
        configBridgeRefreshOperation: ConfigBridgeRefreshOperation? = nil,
        attentionEventDrainOperation: AttentionEventDrainOperation? = nil,
        mainMeterPublicationOperation: MainMeterPublicationOperation? = nil,
        onboardingIsComplete: Bool = true
    ) {
        self.onboardingIsComplete = onboardingIsComplete
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeMeter-AppState-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        self.store = SnapshotStore(directory: directory)
        let suiteName = "ClaudeMeter-AppState-\(id)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        self.codexReadingStore = codexReadingStore ?? CodexReadingStore(defaults: testDefaults)
        self.activationDefaults = testDefaults
        self.ephemeralDefaultsSuiteName = suiteName
        self.ephemeralStoreDirectory = directory
        self.systemIntegrationEnabled = systemIntegrationEnabled
        self.notificationEngine = notificationEngine
        self.isActive = true
        self.hasEnabledDataSource = true
        let appUpdater = AppUpdater(startingUpdater: false)
        self.appUpdater = appUpdater
        self.serviceStatusFetcher = serviceStatusFetcher
        self.oauthEnrichmentFetcher = oauthEnrichmentFetcher
        self.costUsageScanner = costUsageScanner
        self.pollCompletionBarrier = pollCompletionBarrier
        self.configBridgeRefreshOperation =
            configBridgeRefreshOperation
            ?? { request in AppState.performConfigBridgeRefresh(request) }
        self.attentionEventDrainOperation =
            attentionEventDrainOperation
            ?? { disabledAccountKeys, now in
                await Task.detached(priority: .utility) {
                    SessionEventStore.drain(
                        disabledAccountKeys: disabledAccountKeys, now: now)
                }.value
            }
        self.mainMeterPublicationOperation =
            mainMeterPublicationOperation
            ?? { reading, store in
                try MainMeterPublication.replace(reading, in: store)
            }
        self.pipeline = pipeline
        self.snapshot = initialSnapshot
        self.lastPolledAt = initialSnapshot?.lastSuccessfulPollAt
        appUpdater.appState = self
    }

    deinit {
        pollTask?.cancel()
        serviceStatusRefreshTask?.cancel()
        rebuildDebounceTask?.cancel()
        configRefreshTask?.cancel()
        attentionTask?.cancel()
        if let ephemeralStoreDirectory {
            try? FileManager.default.removeItem(at: ephemeralStoreDirectory)
        }
        if let ephemeralDefaultsSuiteName {
            UserDefaults(suiteName: ephemeralDefaultsSuiteName)?.removePersistentDomain(
                forName: ephemeralDefaultsSuiteName)
        }
    }

    func startPolling() {
        let replacedExistingCycle = pollTask != nil || activePollCycleID != nil
        if replacedExistingCycle { invalidatePollGeneration() }
        pollTask?.cancel()
        invalidateActivePollCycle()
        guard onboardingIsComplete else {
            pollTask = nil
            return
        }
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
        let invalidatedExistingCycle = pollTask != nil || activePollCycleID != nil
        if invalidatedExistingCycle { invalidatePollGeneration() }
        pollTask?.cancel()
        pollTask = nil
        invalidateActivePollCycle()
    }

    /// A task can be suspended in Notification Center after its poll generation
    /// changes. Revoke that delivery before abandoning the observation, including
    /// interactive polls whose task is not stored in `pollTask`.
    private func invalidatePollGeneration() {
        notificationEngine.pollFailed()
        pipelineGeneration += 1
    }

    private func invalidateActivePollCycle() {
        activePollCycleID = nil
        isLoading = false
        claudeIsLoading = false
        codexIsLoading = false
        refreshPending = false
        pendingRefreshKind = .background
    }

    /// Called by Settings when an attention toggle flips: reconcile the installed
    /// hooks, (re)start or stop the watcher, and clean up markers when disabled.
    func attentionSettingsChanged() {
        notificationEngine.attentionSettingsChanged()
        refreshConfigBridges()
        startAttentionWatcher()
        if !AppSettings.attentionEnabled { clearAttentionEvents() }
    }

    /// Invalidates any alert that is suspended in a Notification Center call.
    /// The delivery path retracts it when that call resumes.
    func notificationSettingsChanged() {
        notificationEngine.notificationSettingsChanged()
    }

    func checkForUpdates() {
        appUpdater.checkForUpdates()
    }

    /// - Parameter kind: `.interactive` when the user is waiting on the result, so
    ///   the statusline tier's API-fallback cooldown yields rather than serving up
    ///   to `fallbackCooldown` of cache. Wake and reconnect deliberately stay
    ///   `.background`: after either, the cooldown has almost always elapsed on its
    ///   own, so the bypass would buy nothing and only widen how often we can be
    ///   made to call out.
    func refreshNow(kind: RefreshKind = .background) {
        guard canPoll else { return }
        if activePollCycleID != nil {
            refreshPending = true
            if kind == .interactive { pendingRefreshKind = .interactive }
            return
        }
        Task { await poll(kind: kind) }
    }

    func popoverDidOpen() {
        isPopoverOpen = true
        refreshNow(kind: .interactive)
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

    /// Observation age only. A recent last-good value remains fresh even when
    /// the newest refresh attempt failed; callers can inspect `reading.error`
    /// independently.
    var codexIsStale: Bool {
        codexAccounts.contains { $0.observationIsStale() }
    }

    var grokIsStale: Bool {
        AppGroupConfig.isSnapshotStale(lastPollAt: grokLastPolledAt)
    }

    func setCursorSourceEnabled(_ enabled: Bool) {
        optionalSourceSettingDidChange(enabled: enabled, clearState: clearCursorState)
    }

    func clearCursorState() {
        cursorReading = nil
    }

    func setCodexSourceEnabled(_ enabled: Bool) {
        let codexOwnsMainMeter = mainMeterProvider == .codex
        if codexOwnsMainMeter {
            // Disabling clears and publishes account state synchronously. Revoke
            // the old observation before that work can let delivery complete.
            notificationEngine.pollFailed()
        }
        if enabled {
            codexAccounts = codexReadingStore.restore(accounts: AppSettings.codexAccounts())
        }
        optionalSourceSettingDidChange(enabled: enabled, clearState: clearCodexState)
        if codexOwnsMainMeter { finishMainMeterSelectionChange() }
    }

    func clearCodexState() {
        codexAccounts = []
    }

    func refreshCodexAccountsFromSettings(configurationChanged: Bool = false) {
        let codexOwnsMainMeter = mainMeterProvider == .codex
        if configurationChanged {
            invalidatePollGeneration()
        } else if codexOwnsMainMeter {
            // Account restoration and publication can do synchronous work. Revoke
            // the old observation before either operation can expose new state.
            notificationEngine.pollFailed()
        }
        let previousPublishedReading = publishedMainMeterReading
        let previousNotificationReading = lastNotificationReading
        let existing = Dictionary(uniqueKeysWithValues: codexAccounts.map { ($0.id, $0) })
        let restored = Dictionary(
            uniqueKeysWithValues: codexReadingStore.restore(
                accounts: AppSettings.codexAccounts()
            ).map { ($0.id, $0) })
        codexAccounts = AppSettings.codexAccounts().compactMap { account in
            guard let reading = existing[account.id] ?? restored[account.id] else { return nil }
            return CodexAccountReading(
                account: account,
                state: reading.state,
                lastAttemptAt: reading.lastAttemptAt)
        }
        guard codexOwnsMainMeter else { return }
        var currentReading = mainMeterReading
        if MainMeterPolicy.shouldBumpSelectionRevision(
            previous: previousPublishedReading,
            current: currentReading,
            configurationChanged: configurationChanged)
        {
            AppGroupConfig.bumpMainMeterRevision()
            currentReading = mainMeterReading
        }
        if configurationChanged
            || previousNotificationReading?.stableIdentity != currentReading?.stableIdentity
        {
            notificationIdentity = nil
            allowsPersistedNotificationRecovery = false
        }
        publishMainMeterReading()
        if configurationChanged
            || MainMeterPolicy.shouldReloadWidget(
                previous: previousPublishedReading,
                current: currentReading)
        {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func setGrokSourceEnabled(_ enabled: Bool) {
        optionalSourceSettingDidChange(enabled: enabled, clearState: clearGrokState)
    }

    private func optionalSourceSettingDidChange(
        enabled: Bool,
        clearState: () -> Void
    ) {
        // Invalidates every task in the old poll cycle. `startPolling()` cancels
        // its parent task, but detached timeout work can finish later.
        invalidatePollGeneration()
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        if enabled {
            if isActive { startPolling() }
        } else {
            clearState()
            if !canPoll {
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
        if mainMeterProvider == .claude {
            // The setting changed before the debounce starts. Revoke its old
            // observation now instead of leaving it live during the delay.
            notificationEngine.pollFailed()
        }
        rebuildDebounceTask?.cancel()
        rebuildDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.rebuildDebounceMilliseconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.rebuildPipeline()
            }
        }
    }

    func rebuildPipeline() {
        let claudeOwnsMainMeter = mainMeterProvider == .claude
        invalidatePollGeneration()
        lastOAuthEnrichmentAttemptAt = nil
        oauthEnrichmentReading = nil
        oauthEnrichmentAccountKey = nil
        lastAccountsFetchAt = nil
        cachedAccountReadings = []
        accountOAuthFailures = [:]
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        pipeline = AppState.makePipeline(store: store)
        if claudeOwnsMainMeter { finishMainMeterSelectionChange() }
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
        if !active {
            // Revoke suspended deliveries before settings, published state, or
            // task cancellation can let independent notification work resume.
            notificationEngine.pollFailed()
            notificationEngine.attentionSettingsChanged()
        }
        activationDefaults.set(active, forKey: AppSettings.isActiveKey)
        isActive = active
        refreshPending = false
        pendingRefreshKind = .background
        if active {
            rebuildPipeline()
        } else {
            stopPolling()
            startAttentionWatcher()  // self-cancels now that isActive == false
            isLoading = false
        }
    }

    /// Releases the first-run gate and starts the normal background lifecycle.
    /// The persistent Fetch Usage preference remains authoritative.
    func completeOnboarding() {
        guard !onboardingIsComplete else { return }
        onboardingIsComplete = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        startPolling()
        Task { await notificationEngine.requestAuthorizationIfNeeded() }
    }

    /// Existing installs must not see first-run onboarding after an upgrade.
    /// Keychain probes are attributes-only and never read credential contents.
    private var hasExistingUserEvidence: Bool {
        Self.existingUserEvidenceIsPresent(
            snapshotExists: snapshot != nil,
            automaticOAuthAvailability: OAuthKeychain.credentialAvailability(),
            manualOAuthAvailability: OAuthKeychain.manualCredentialAvailability(),
            cursorStateExists: CursorTokenStore.isStateDBPresent(),
            codexUsageExists: codexAccounts.contains(where: { $0.usage != nil }),
            codexConfigurationExists: Self.codexConfigurationExists,
            statuslineDataDirectoryExists: FileManager.default.fileExists(
                atPath: StatuslineBridge.statuslineFilePath.deletingLastPathComponent().path)
        )
    }

    /// Pure onboarding-decision seam. A transient Keychain error is not evidence
    /// that a credential exists, so a new user still sees onboarding while the
    /// Keychain is locked or otherwise unavailable.
    nonisolated static func existingUserEvidenceIsPresent(
        snapshotExists: Bool,
        automaticOAuthAvailability: KeychainCredentialAvailability,
        manualOAuthAvailability: KeychainCredentialAvailability,
        cursorStateExists: Bool,
        codexUsageExists: Bool,
        codexConfigurationExists: Bool,
        statuslineDataDirectoryExists: Bool
    ) -> Bool {
        snapshotExists
            || automaticOAuthAvailability == .available
            || manualOAuthAvailability == .available
            || cursorStateExists
            || codexUsageExists
            || codexConfigurationExists
            || statuslineDataDirectoryExists
    }

    private static var codexConfigurationExists: Bool {
        guard AppSettings.codexSourceEnabled else { return false }
        return AppSettings.codexAccounts().contains { account in
            FileManager.default.fileExists(
                atPath: account.home.appendingPathComponent("auth.json").path)
                || FileManager.default.fileExists(
                    atPath: account.home.appendingPathComponent("config.toml").path)
        }
    }

    static func currentThresholds() -> UsageThresholds {
        AppGroupConfig.currentThresholds()
    }

    private func poll(kind: RefreshKind = .background) async {
        guard canPoll else { return }
        refreshConfigBridges()  // self-heal statusline + attention hooks each poll
        guard activePollCycleID == nil else {
            refreshPending = true
            if kind == .interactive { pendingRefreshKind = .interactive }
            return
        }
        nextPollCycleID &+= 1
        let cycleID = nextPollCycleID
        activePollCycleID = cycleID
        let configuration = PollConfiguration(
            generation: pipelineGeneration, refreshKind: kind)
        isLoading = true
        defer { finishPollCycle(cycleID) }

        await withTaskGroup(of: Void.self) { group in
            if configuration.claudeEnabled {
                group.addTask {
                    await self.pollClaude(configuration: configuration, cycleID: cycleID)
                }
            }
            if configuration.cursorEnabled {
                group.addTask { await self.pollCursor(configuration: configuration) }
            }
            if configuration.codexEnabled {
                group.addTask {
                    await self.pollCodex(configuration: configuration, cycleID: cycleID)
                }
            }
            if configuration.grokEnabled {
                group.addTask { await self.pollGrok(configuration: configuration) }
            }
        }
        await pollCompletionBarrier?()
    }

    private func finishPollCycle(_ cycleID: UInt64) {
        guard activePollCycleID == cycleID else { return }
        activePollCycleID = nil
        isLoading = false
        claudeIsLoading = false
        codexIsLoading = false
        guard refreshPending else { return }
        refreshPending = false
        let pending = pendingRefreshKind
        pendingRefreshKind = .background
        Task { await poll(kind: pending) }
    }

    private func pollClaude(configuration: PollConfiguration, cycleID: UInt64) async {
        guard activePollCycleID == cycleID else { return }
        claudeIsLoading = true
        defer {
            if activePollCycleID == cycleID { claudeIsLoading = false }
        }
        let pipeline = self.pipeline
        let now = Date()
        let previousPublishedReading = publishedMainMeterReading
        let previousNotificationReading = lastNotificationReading
        scheduleServiceStatusRefresh(generation: configuration.generation)
        do {
            let result = try await Timeout.run(seconds: Self.pollTimeoutSeconds) {
                try await pipeline.poll(now: now, kind: configuration.refreshKind)
            }
            guard configuration.generation == pipelineGeneration, canPoll else { return }

            lastPollResult = result

            if result.isFatal {
                recordClaudePollFailure(
                    result.errors.map(\.message).joined(separator: "; "),
                    generation: configuration.generation)
                return
            }

            if var snap = result.snapshot {
                // Enrich with per-model token/cost usage scanned from local logs.
                // Independent of which tier produced the rate-limit snapshot.
                let costResult: CostUsageResult
                do {
                    let scan = costUsageScanner
                    costResult = try await Timeout.run(
                        seconds: Self.transcriptScanTimeoutSeconds,
                        budget: Self.transcriptScanTimeoutBudget
                    ) {
                        await scan(now, configuration)
                    }
                } catch {
                    costResult = CostUsageResult(models: [], isPartialEstimate: true)
                }
                guard configuration.generation == pipelineGeneration, canPoll else { return }
                Self.applyCostModels(costResult, to: &snap)
                // Opus weekly, extra-usage spend, and plan live only in the OAuth
                // response. When statusline produced the snapshot, layer those
                // fields on if OAuth credentials are available.
                let enrichment = await oauthEnrichment(
                    for: snap, now: now, configuration: configuration)
                guard configuration.generation == pipelineGeneration, canPoll else { return }
                if let enrichment {
                    Self.apply(
                        enrichment, to: &snap, sourceAccountKey: oauthEnrichmentAccountKey)
                }
                let topLevelOAuthDetailsObservedAt = Self.topLevelOAuthDetailsObservedAt(
                    for: snap,
                    enrichmentObservedAt: enrichment.flatMap { _ in
                        oauthEnrichmentReading?.lastPolledAt
                    })
                // Per-account OAuth readings (multi-account tier): fill each
                // account's plan/email/Opus/extra and cover accounts with no
                // live session. A post-reset OAuth reading can also replace an
                // expired statusline window whose displayed 0% is only inferred.
                let readings = await accountReadings(now: now, configuration: configuration)
                guard configuration.generation == pipelineGeneration, canPoll else { return }
                let mergedSnap = MultiAccountOAuth.merge(
                    readings: readings,
                    into: snap,
                    now: now,
                    thresholds: configuration.thresholds,
                    activeTopLevelOAuthDetailsObservedAt: topLevelOAuthDetailsObservedAt)
                snap = mergedSnap
                costScanPartial = costResult.isPartialEstimate
                do {
                    try store.writeLatest(snap)
                    try store.clearLastError()
                } catch {
                    // Persistence is best-effort. The guarded in-memory reading is
                    // still authoritative for this process.
                }
                snapshot = snap
                if let successfulPollAt = snap.lastSuccessfulPollAt {
                    lastPolledAt = successfulPollAt
                }
                if mainMeterProvider == .claude {
                    var currentReading = mainMeterReading
                    if MainMeterPolicy.shouldBumpSelectionRevision(
                        previous: previousPublishedReading,
                        current: currentReading,
                        configurationChanged: false)
                    {
                        AppGroupConfig.bumpMainMeterRevision()
                        notificationIdentity = nil
                        allowsPersistedNotificationRecovery = false
                        currentReading = mainMeterReading
                    }
                    if let currentReading {
                        await processMainMeterObservation(
                            currentReading,
                            previous: previousNotificationReading,
                            isStale: claudeIsStale || snap.state.isStale,
                            generation: configuration.generation)
                        guard configuration.generation == pipelineGeneration, canPoll else {
                            return
                        }
                    }
                    publishMainMeterReading()
                    if MainMeterPolicy.shouldReloadWidget(
                        previous: previousPublishedReading,
                        current: currentReading)
                    {
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
            } else {
                // No snapshot at all — not a fresh reading, so it must not count
                // toward the selected meter's predictive confirmation.
                if mainMeterProvider == .claude { notificationEngine.pollFailed() }
            }

            // A successful poll clears the error; tier failures remain available
            // through the sanitized source-attempt trail.
            lastError = nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recordClaudePollFailure(message, generation: configuration.generation)
        }
    }

    /// Records only the active Claude poll generation. The app owns this final
    /// persistence step because provider tiers do not write shared snapshots.
    private func recordClaudePollFailure(_ message: String, generation: Int) {
        guard generation == pipelineGeneration, canPoll else { return }
        let sanitized = DiagnosticsSanitizer.sanitize(message)
        lastError = sanitized
        try? store.writeLastError(LastErrorRecord(message: sanitized))
        if mainMeterProvider == .claude { notificationEngine.pollFailed() }
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

    /// Codex runs independently of Claude and Cursor. It owns shared meter output
    /// only when the user explicitly selects Codex as the main meter.
    private func pollCodex(configuration: PollConfiguration, cycleID: UInt64) async {
        guard activePollCycleID == cycleID else { return }
        codexIsLoading = true
        defer {
            if activePollCycleID == cycleID { codexIsLoading = false }
        }
        let now = Date()
        let previous = Dictionary(uniqueKeysWithValues: codexAccounts.map { ($0.id, $0) })
        let previousPublishedReading = publishedMainMeterReading
        let previousNotificationReading = lastNotificationReading
        let accounts = configuration.codexAccounts
        let readings = await Self.fetchCodexAccountReadings(
            accounts: accounts,
            previous: previous,
            mode: configuration.codexMode,
            now: now,
            perAccountTimeoutSeconds: Self.pollTimeoutSeconds,
            totalTimeoutSeconds: Self.pollTimeoutSeconds,
            budget: Self.codexPollTimeoutBudget
        ) { account, mode, now in
            try await CodexUsageProvider(codexHome: account.home).fetchUsage(
                mode: mode, now: now)
        }
        guard configuration.generation == pipelineGeneration,
            canPoll,
            AppSettings.codexSourceEnabled
        else { return }
        let byID = Dictionary(uniqueKeysWithValues: readings.map { ($0.id, $0) })
        codexAccounts = accounts.compactMap { byID[$0.id] }
        codexReadingStore.save(codexAccounts)

        guard mainMeterProvider == .codex else { return }
        var currentSelected = mainMeterReading
        if MainMeterPolicy.shouldBumpSelectionRevision(
            previous: previousPublishedReading,
            current: currentSelected,
            configurationChanged: false)
        {
            AppGroupConfig.bumpMainMeterRevision()
            notificationIdentity = nil
            allowsPersistedNotificationRecovery = false
            currentSelected = mainMeterReading
        }
        publishMainMeterReading()
        if let currentSelected,
            let lifecycle = codexAccounts.first(where: { $0.id == currentSelected.accountID })
        {
            if case .current = lifecycle.state {
                await processMainMeterObservation(
                    currentSelected,
                    previous: previousNotificationReading,
                    isStale: mainMeterIsStale,
                    generation: configuration.generation)
                guard configuration.generation == pipelineGeneration, canPoll else { return }
            } else {
                notificationEngine.pollFailed()
            }
        } else {
            notificationEngine.pollFailed()
        }
        if MainMeterPolicy.shouldReloadWidget(
            previous: previousPublishedReading,
            current: currentSelected)
        {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Fetches Codex accounts in batches of three under one provider-wide
    /// deadline. Accounts that do not start before the deadline still receive a
    /// coherent failed/stale lifecycle result.
    nonisolated static func fetchCodexAccountReadings(
        accounts: [CodexAccount],
        previous: [String: CodexAccountReading],
        mode: CodexSourceMode,
        now: Date,
        perAccountTimeoutSeconds: TimeInterval,
        totalTimeoutSeconds: TimeInterval,
        budget: Timeout.TaskBudget,
        fetch: @escaping CodexUsageFetchOperation
    ) async -> [CodexAccountReading] {
        let totalTimeout =
            totalTimeoutSeconds.isFinite && totalTimeoutSeconds > 0
            ? totalTimeoutSeconds : 0
        let deadline = ProcessInfo.processInfo.systemUptime + totalTimeout
        var readings: [CodexAccountReading] = []
        var nextIndex = 0

        while nextIndex < accounts.count {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                let error = TimeoutError(seconds: totalTimeoutSeconds)
                for account in accounts[nextIndex...] {
                    readings.append(
                        failedCodexReading(
                            account: account, prior: previous[account.id], error: error))
                }
                break
            }

            let endIndex = min(nextIndex + 3, accounts.count)
            let batch = Array(accounts[nextIndex..<endIndex])
            let accountTimeout = min(perAccountTimeoutSeconds, remaining)
            let results = await withTaskGroup(of: CodexAccountReading.self) { group in
                for account in batch {
                    let prior = previous[account.id]
                    group.addTask {
                        do {
                            let usage = try await Timeout.run(
                                seconds: accountTimeout, budget: budget
                            ) {
                                try await fetch(account, mode, now)
                            }
                            let completedAt = Date()
                            return CodexAccountReading(
                                account: account,
                                state: .current(value: usage, polledAt: completedAt),
                                lastAttemptAt: completedAt)
                        } catch {
                            return failedCodexReading(
                                account: account, prior: prior, error: error)
                        }
                    }
                }
                var batchReadings: [CodexAccountReading] = []
                for await reading in group { batchReadings.append(reading) }
                return batchReadings
            }
            readings.append(contentsOf: results)
            nextIndex = endIndex
        }

        let readingsByID = readings.reduce(into: [String: CodexAccountReading]()) {
            $0[$1.id] = $1
        }
        return accounts.compactMap { readingsByID[$0.id] }
    }

    nonisolated private static func failedCodexReading(
        account: CodexAccount,
        prior: CodexAccountReading?,
        error: any Error
    ) -> CodexAccountReading {
        let message = DiagnosticsSanitizer.sanitize(
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        let attemptedAt = Date()
        if let usage = prior?.usage, let polledAt = prior?.lastSuccessfulAt {
            return CodexAccountReading(
                account: account,
                state: .stale(value: usage, polledAt: polledAt, error: message),
                lastAttemptAt: attemptedAt)
        }
        return CodexAccountReading(
            account: account,
            state: .failed(error: message, lastPolledAt: nil),
            lastAttemptAt: attemptedAt)
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

    /// Starts one best-effort Anthropic status refresh without joining it to the
    /// authoritative usage task. Repeated interactive polls coalesce while the
    /// advisory request is in flight.
    func scheduleServiceStatusRefresh(generation: Int) {
        guard serviceStatusRefreshTask == nil else { return }
        let fetch = serviceStatusFetcher
        serviceStatusRefreshTask = Task { [weak self] in
            let status = await fetch()
            guard let self else { return }
            defer { self.serviceStatusRefreshTask = nil }
            guard !Task.isCancelled,
                generation == self.pipelineGeneration,
                self.canPoll
            else { return }
            self.serviceStatus = status
        }
    }

    /// Fetches OAuth-only enrichment (Opus window, extra usage, plan) when the
    /// snapshot came from a non-OAuth source and OAuth creds are available. Returns
    /// `nil` when not applicable. An OAuth-produced snapshot already has these.
    private func oauthEnrichment(
        for snap: ClaudeUsageSnapshot,
        now: Date,
        configuration: PollConfiguration
    ) async -> OAuthPipeline.OAuthEnrichment? {
        guard configuration.oauthEnabled,
            configuration.oauthMode == "auto",
            snap.source.cliPath != "api.anthropic.com"
        else {
            lastOAuthEnrichmentAttemptAt = nil
            oauthEnrichmentReading = nil
            oauthEnrichmentAccountKey = nil
            return nil
        }
        if let lastOAuthEnrichmentAttemptAt,
            now.timeIntervalSince(lastOAuthEnrichmentAttemptAt)
                < Self.oauthEnrichmentIntervalSeconds
        {
            if let oauthEnrichmentReading {
                self.oauthEnrichmentReading = Self.resolvedOAuthEnrichmentReading(
                    oauthEnrichmentReading, asOf: now)
            }
            return await matchingOAuthEnrichment(for: snap, configuration: configuration)
        }
        let result = await oauthEnrichmentFetcher(now)
        guard configuration.generation == pipelineGeneration, canPoll else { return nil }
        lastOAuthEnrichmentAttemptAt = now
        oauthEnrichmentReading = Self.updatedOAuthEnrichmentReading(
            previous: oauthEnrichmentReading,
            result: result,
            now: now
        )
        return await matchingOAuthEnrichment(for: snap, configuration: configuration)
    }

    /// Single-slot credentials need an exact account match before their cached or
    /// fresh details can supplement statusline data. Active-account changes do not
    /// rebuild the pipeline, and the newest Keychain login can be a different one.
    private func matchingOAuthEnrichment(
        for snapshot: ClaudeUsageSnapshot,
        configuration: PollConfiguration
    ) async -> OAuthPipeline.OAuthEnrichment? {
        guard let enrichment = oauthEnrichmentReading?.value,
            let service = enrichment.credentialService
        else {
            oauthEnrichmentAccountKey = nil
            return nil
        }
        var accountKey = OAuthKeychain.accountKey(forCredentialService: service, accounts: [])
        if accountKey == nil {
            let configuredDirs = configuration.configuredClaudeDirs
            accountKey = try? await Timeout.run(seconds: 5) {
                OAuthKeychain.accountKey(
                    forCredentialService: service,
                    accounts: ConfigDirDiscovery.discover(configuredDirs: configuredDirs))
            }
            guard configuration.generation == pipelineGeneration, canPoll else { return nil }
        }
        oauthEnrichmentAccountKey = accountKey
        guard accountKey == (snapshot.activeAccountID ?? "claude") else { return nil }
        return enrichment
    }

    static func updatedOAuthEnrichmentReading(
        previous: ReadingState<OAuthPipeline.OAuthEnrichment>?,
        result: OAuthPipeline.OAuthEnrichmentFetchResult,
        now: Date
    ) -> ReadingState<OAuthPipeline.OAuthEnrichment> {
        let updated: ReadingState<OAuthPipeline.OAuthEnrichment>
        switch result {
        case .success(let enrichment):
            updated = .current(value: enrichment, polledAt: now)
        case .unavailable(let reason):
            let error = reason.rawValue
            if let value = previous?.value, let observedAt = previous?.lastPolledAt {
                updated = .stale(value: value, polledAt: observedAt, error: error)
            } else {
                updated = .failed(error: error, lastPolledAt: previous?.lastPolledAt)
            }
        }
        return resolvedOAuthEnrichmentReading(updated, asOf: now)
    }

    /// Clears limits from a cached OAuth observation after their reset boundary.
    /// The cached value cannot describe usage that accumulated in the new rolling
    /// window. Plan and extra-usage fields remain valid on their own cadence.
    static func resolvedOAuthEnrichmentReading(
        _ reading: ReadingState<OAuthPipeline.OAuthEnrichment>,
        asOf now: Date
    ) -> ReadingState<OAuthPipeline.OAuthEnrichment> {
        switch reading {
        case .current(let value, let observedAt):
            return .current(
                value: resolvedOAuthEnrichment(value, observedAt: observedAt, asOf: now),
                polledAt: observedAt)
        case .stale(let value, let observedAt, let error):
            return .stale(
                value: resolvedOAuthEnrichment(value, observedAt: observedAt, asOf: now),
                polledAt: observedAt,
                error: error)
        case .failed:
            return reading
        }
    }

    private static func resolvedOAuthEnrichment(
        _ enrichment: OAuthPipeline.OAuthEnrichment,
        observedAt: Date,
        asOf now: Date
    ) -> OAuthPipeline.OAuthEnrichment {
        func resolvedWindow(_ window: LimitWindow) -> LimitWindow? {
            guard let resetAt = window.resetsAt, resetAt <= now else { return window }
            guard observedAt >= resetAt else { return nil }
            return window.resolved(asOf: now)
        }

        return OAuthPipeline.OAuthEnrichment(
            opus: enrichment.opus.flatMap(resolvedWindow),
            scopedWeekly: enrichment.scopedWeekly.map { scoped in
                scoped.compactMap { limit in
                    resolvedWindow(limit.window).map {
                        ScopedLimitWindow(id: limit.id, window: $0)
                    }
                }
            },
            extraUsage: enrichment.extraUsage,
            plan: enrichment.plan,
            credentialService: enrichment.credentialService)
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
    private func accountReadings(
        now: Date,
        configuration: PollConfiguration
    ) async -> [OAuthAccountReading] {
        guard configuration.oauthEnabled, configuration.oauthMode == "auto"
        else {
            accountOAuthFailures = [:]
            return []
        }
        let disabledKeys = configuration.disabledClaudeAccountKeys
        let enabledCachedReadings = Self.enabledCachedAccountReadings(
            cachedAccountReadings,
            disabledKeys: disabledKeys)
        if let lastAccountsFetchAt,
            now.timeIntervalSince(lastAccountsFetchAt) < Self.oauthEnrichmentIntervalSeconds
        {
            return enabledCachedReadings
        }
        let configuredDirs = configuration.configuredClaudeDirs
        let accounts: [AccountConfig]
        do {
            accounts = try await Timeout.run(seconds: 5) {
                ConfigDirDiscovery.discover(
                    configuredDirs: configuredDirs, disabledKeys: disabledKeys)
            }
        } catch {
            guard configuration.generation == pipelineGeneration, canPoll else {
                return enabledCachedReadings
            }
            lastAccountsFetchAt = now
            accountOAuthFailures = Dictionary(
                uniqueKeysWithValues: enabledCachedReadings.map {
                    ($0.accountKey, .requestFailed)
                })
            return enabledCachedReadings
        }
        guard configuration.generation == pipelineGeneration, canPoll else {
            return enabledCachedReadings
        }

        let accountKeys = accounts.map(\.id)
        let home = FileManager.default.homeDirectoryForCurrentUser
        // The provider owns both the total deadline and each account deadline.
        // It returns completed results when a later account times out.
        let results = await MultiAccountOAuth.fetchAllResults(
            accounts: accounts,
            home: home,
            thresholds: configuration.thresholds,
            transport: ProviderHTTPClient.shared,
            credentialsLoader: { path, isDefault in
                OAuthKeychain.loadResult(configDirPath: path, isDefault: isDefault)
            },
            now: now)
        guard configuration.generation == pipelineGeneration, canPoll else {
            return enabledCachedReadings
        }

        lastAccountsFetchAt = now
        cachedAccountReadings = Self.mergedCachedAccountReadings(
            previous: enabledCachedReadings,
            successful: results.compactMap(\.reading),
            validAccountKeys: accountKeys)
        var failures = Dictionary(
            uniqueKeysWithValues: results.compactMap { result in
                result.failure.map { (result.accountKey, $0) }
            })
        let reportedKeys = Set(results.map(\.accountKey))
        let missingFailure: MultiAccountOAuth.AccountFetchFailure =
            OAuthPipeline.rateLimitedUntil(now: now) != nil ? .rateLimited : .requestFailed
        for key in accountKeys where !reportedKeys.contains(key) {
            failures[key] = missingFailure
        }
        accountOAuthFailures = failures
        return cachedAccountReadings
    }

    /// A discovery timeout must not restore an account that the captured poll
    /// configuration disabled. The default Claude account is always enabled.
    nonisolated static func enabledCachedAccountReadings(
        _ readings: [OAuthAccountReading],
        disabledKeys: Set<String>
    ) -> [OAuthAccountReading] {
        readings.filter {
            $0.accountKey == "claude" || !disabledKeys.contains($0.accountKey)
        }
    }

    /// Replaces successful accounts in place, retains last-good values for failed
    /// accounts, and removes values only when the account is no longer enabled.
    nonisolated static func mergedCachedAccountReadings(
        previous: [OAuthAccountReading],
        successful: [OAuthAccountReading],
        validAccountKeys: [String]
    ) -> [OAuthAccountReading] {
        var byKey = Dictionary(
            previous.map { ($0.accountKey, $0) },
            uniquingKeysWith: { current, _ in current })
        for reading in successful {
            byKey[reading.accountKey] = reading
        }
        return validAccountKeys.compactMap { byKey[$0] }
    }

    /// Applies a complete scan even when it found no usage. An empty partial scan
    /// can mean a timeout or unreadable root, so it keeps the prior last-good list.
    @discardableResult
    nonisolated static func applyCostModels(
        _ result: CostUsageResult,
        to snapshot: inout ClaudeUsageSnapshot
    ) -> Bool {
        guard !result.models.isEmpty || !result.isPartialEstimate else { return false }
        guard snapshot.models != result.models else { return false }
        snapshot.models = result.models
        return true
    }

    @discardableResult
    static func apply(
        _ e: OAuthPipeline.OAuthEnrichment, to snap: inout ClaudeUsageSnapshot,
        sourceAccountKey: String?
    ) -> Bool {
        guard sourceAccountKey == (snap.activeAccountID ?? "claude") else { return false }
        // Enrichment is a complete successful observation, not a sparse patch.
        // Replacing optionals lets the API explicitly remove a limit that existed
        // in an earlier response; a failed fetch never reaches this method.
        snap.limits.currentWeekOpus = e.opus
        snap.limits.scopedWeekly = e.scopedWeekly
        snap.limits.extraUsage = e.extraUsage

        if var account = snap.account {
            account.plan = e.plan
            snap.account = account.isEmpty ? nil : account
        } else if let plan = e.plan {
            snap.account = AccountInfo(plan: plan)
        }
        return true
    }

    nonisolated static func topLevelOAuthDetailsObservedAt(
        for snapshot: ClaudeUsageSnapshot,
        enrichmentObservedAt: Date?
    ) -> Date? {
        if snapshot.source.cliPath == "api.anthropic.com" {
            return snapshot.lastSuccessfulPollAt ?? snapshot.createdAt
        }
        return enrichmentObservedAt
    }

    /// Scans local Claude Code transcripts for per-model token/cost usage (last 7
    /// days), unioned across every discovered config dir (cost is additive).
    /// Discovery happens here, off-main, rather than reusing a cached list — so the
    /// union is correct from the very first poll, independent of the statusline source.
    private static func scanCostModels(
        now: Date,
        configuration: PollConfiguration
    ) async -> CostUsageResult {
        // The caller runs this method in a bounded detached task. Do not add a
        // second unstructured task here because it would escape that deadline.
        let catalog = await ModelsDevPricing.loadCatalog(now: now)
        let accounts = ConfigDirDiscovery.discover(
            configuredDirs: configuration.configuredClaudeDirs,
            disabledKeys: configuration.disabledClaudeAccountKeys)
        let paths =
            accounts.isEmpty
            ? [JournalReader.defaultProjectsPath] : accounts.map(\.projectsPath)
        let pricing = ModelPricing.current.withCatalog(catalog)
        return CostUsageScanner(projectsPaths: paths, pricing: pricing).scan(
            daysBack: 7, now: now)
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
        let configuredDirs = AppGroupConfig.configuredConfigDirs
        let disabledKeys = Set(AppGroupConfig.disabledAccountKeys)
        activityHeatmapTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: ActivityHeatmap?
            do {
                result = try await Timeout.run(
                    seconds: Self.transcriptScanTimeoutSeconds,
                    budget: Self.transcriptScanTimeoutBudget
                ) {
                    let accounts = ConfigDirDiscovery.discover(
                        configuredDirs: configuredDirs, disabledKeys: disabledKeys)
                    let paths =
                        accounts.isEmpty
                        ? [JournalReader.defaultProjectsPath] : accounts.map(\.projectsPath)
                    return ActivityScanner(projectsPaths: paths).scan(daysBack: 30, now: now)
                }
            } catch is CancellationError {
                result = nil
            } catch {
                result = ActivityHeatmap(
                    counts: Array(repeating: Array(repeating: 0, count: 24), count: 7),
                    total: 0,
                    isPartial: true,
                    daysCovered: 0)
            }
            let cancelled = Task.isCancelled
            await MainActor.run { [weak self] in
                guard let self, self.activityHeatmapGeneration == generation else { return }
                if !cancelled, let result { self.activityHeatmap = result }
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

    // MARK: - Pipeline factory

    private static func makePipeline(store: SnapshotStore) -> any ClaudeMeterPipeline {
        let thresholds = AppGroupConfig.currentThresholds()
        var pipeline: any ClaudeMeterPipeline = CachedSnapshotPipeline(store: store)

        if AppSettings.oauthSourceEnabled {
            let configuredDirs = AppGroupConfig.configuredConfigDirs
            pipeline = OAuthPipeline(
                fallback: pipeline, store: store, thresholds: thresholds,
                accountConfigs: { ConfigDirDiscovery.discover(configuredDirs: configuredDirs) })
        }

        if AppSettings.statuslineSourceEnabled {
            pipeline = StatuslinePipeline(
                fallback: pipeline,
                store: store,
                thresholds: thresholds,
                disabledAccountKeys: Set(AppGroupConfig.disabledAccountKeys)
            )
        }

        return DisabledClaudeAccountFilteringPipeline(
            upstream: pipeline,
            disabledAccountKeys: Set(AppGroupConfig.disabledAccountKeys))
    }

    private var canPoll: Bool {
        onboardingIsComplete && isActive && AppSettings.hasEnabledDataSource
    }

    /// Installs/self-heals the statusline bridge and attention hooks in one
    /// serialized off-main task. Requests during a run coalesce into one rerun.
    private func refreshConfigBridges() {
        guard onboardingIsComplete, systemIntegrationEnabled else { return }
        if configRefreshTask != nil {
            configRefreshRerunRequested = true
            return
        }

        let request = ConfigBridgeRefreshRequest(
            statuslineEnabled: AppSettings.statuslineSourceEnabled,
            attentionEvents: AppSettings.enabledAttentionEvents,
            configuredDirs: AppGroupConfig.configuredConfigDirs,
            disabledAccountKeys: Set(AppGroupConfig.disabledAccountKeys),
            store: store)
        let operation = configBridgeRefreshOperation
        configRefreshID &+= 1
        let refreshID = configRefreshID
        configRefreshOperationCount += 1
        configRefreshTask = Task.detached(priority: .utility) { [weak self] in
            await operation(request)
            await self?.configBridgeRefreshDidFinish(refreshID)
        }
    }

    private func configBridgeRefreshDidFinish(_ refreshID: UInt64) {
        guard refreshID == configRefreshID else { return }
        configRefreshTask = nil
        guard configRefreshRerunRequested else { return }
        configRefreshRerunRequested = false
        refreshConfigBridges()
    }

    /// Test seam for the coalescing lifecycle. Production callers use the private
    /// method through polling and settings changes.
    func refreshConfigBridgesForTesting() {
        refreshConfigBridges()
    }

    func persistedSnapshotForTesting() -> ClaudeUsageSnapshot? {
        try? store.readLatest()
    }

    func persistedLastErrorForTesting() -> LastErrorRecord? {
        try? store.readLastError()
    }

    nonisolated private static func performConfigBridgeRefresh(
        _ request: ConfigBridgeRefreshRequest
    ) {
        // Global removal must see disabled accounts too. Apply the disabled filter
        // only to installation and reads.
        let allAccounts = ConfigDirDiscovery.discover(
            configuredDirs: request.configuredDirs, disabledKeys: [])
        let enabledAccounts = allAccounts.filter {
            $0.id == StatuslineBridge.defaultAccountKey
                || !request.disabledAccountKeys.contains($0.id)
        }
        let enabledDirs = enabledAccounts.map(\.configDir)
        let disabledDirs = allAccounts.filter {
            $0.id != StatuslineBridge.defaultAccountKey
                && request.disabledAccountKeys.contains($0.id)
        }.map(\.configDir)
        let allDirs = allAccounts.map(\.configDir)
        var firstError: Error?

        if request.statuslineEnabled {
            do {
                try StatuslineBridge.install(configDirs: enabledDirs)
            } catch {
                if firstError == nil { firstError = error }
            }
            do {
                _ = try StatuslineBridge.uninstall(configDirs: disabledDirs)
            } catch {
                if firstError == nil { firstError = error }
            }
        } else {
            do {
                if try StatuslineBridge.uninstall(configDirs: allDirs) {
                    StatuslineBridge.purgeSessionData()
                }
            } catch let error as StatuslineBridge.UninstallError {
                if error.didChange { StatuslineBridge.purgeSessionData() }
                if firstError == nil { firstError = error }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if request.attentionEvents.isEmpty {
            do {
                try HookBridge.install(configDirs: allDirs, events: [])
            } catch {
                if firstError == nil { firstError = error }
            }
        } else {
            do {
                try HookBridge.install(
                    configDirs: enabledDirs, events: request.attentionEvents)
            } catch {
                if firstError == nil { firstError = error }
            }
            do {
                try HookBridge.install(configDirs: disabledDirs, events: [])
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError {
            let message =
                (firstError as? LocalizedError)?.errorDescription
                ?? firstError.localizedDescription
            try? request.store.writeLastError(
                LastErrorRecord(message: DiagnosticsSanitizer.sanitize(message)))
        }
    }

    // MARK: - Attention (Claude Code hooks)

    /// Drains attention markers and fires a native notification per event, on its
    /// own energy-aware cadence (independent of the meter poll): backs off to the
    /// asleep recheck while the display is asleep, and stretches on battery — macOS
    /// owns sound, Focus/DND, and Notification-Center history.
    private func startAttentionWatcher() {
        attentionTask?.cancel()
        guard systemIntegrationEnabled, onboardingIsComplete, isActive,
            AppSettings.attentionEnabled
        else {
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
        let events = await attentionEventDrainOperation(disabled, now)
        // A wake or configuration rebuild replaces the watcher while attention is
        // still enabled. Finish events that this drain already removed from disk;
        // the loop cancellation still stops the old watcher after this iteration.
        guard isActive, onboardingIsComplete, AppSettings.attentionEnabled
        else { return }
        guard !events.isEmpty else { return }

        let engine = notificationEngine
        let enabled = AppSettings.enabledAttentionEvents
        let attentionLease = engine.attentionLease()
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
            Task {
                await engine.postAttention(
                    event: event,
                    accountLabel: account,
                    expectedRevision: attentionLease)
            }
        }
        // A limit block is ground truth that usage maxed out — re-poll now so the
        // meter reflects it immediately instead of waiting for the next interval.
        if sawLimitBlock { refreshNow() }
    }

    @discardableResult
    func startAttentionWatcherForTesting() -> Task<Void, Never>? {
        startAttentionWatcher()
        return attentionTask
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

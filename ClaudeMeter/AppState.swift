import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var updateAvailable = false
    @Published private(set) var isActive: Bool
    @Published private(set) var hasEnabledDataSource: Bool

    let usageStore: UsageStore
    let refreshScheduler: RefreshScheduler
    private var usageStoreChanges: AnyCancellable?

    /// Test meters keep pause/resume writes out of the installed app's settings.
    private let activationDefaults: UserDefaults
    private let ephemeralDefaultsSuiteName: String?
    private let appUpdater: AppUpdater
    /// First-run onboarding blocks polling until the user chooses Get Started.
    private var onboardingIsComplete: Bool

    /// Configured Codex homes, canonicalized when the configuration changes so that
    /// rendering does no path resolution. The adapter resolves its own copy for each
    /// refresh; this list only labels and orders accounts.
    private(set) var codexConfiguration: [CodexAccount] = AppSettings.codexAccounts()

    var codexIsLoading: Bool { usageStore.refreshing.contains(.codex) }
    var codexAccounts: [ProviderAccountSnapshot] {
        let accounts = usageStore.reading(for: .codex)?.value?.accounts ?? []
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        // Settings own labels/order. A removed pin becomes unavailable immediately.
        return codexConfiguration.compactMap { configuration in
            guard var account = byID[configuration.id] else { return nil }
            account.label = configuration.displayName
            return account
        }
    }
    var cursorSnapshot: ProviderSnapshot? { usageStore.reading(for: .cursor)?.value }
    var cursorError: String? { usageStore.reading(for: .cursor)?.error }
    var cursorLastPolledAt: Date? { usageStore.reading(for: .cursor)?.lastPolledAt }
    var grokSnapshot: ProviderSnapshot? { usageStore.reading(for: .grok)?.value }
    var grokError: String? { usageStore.reading(for: .grok)?.error }
    var grokLastPolledAt: Date? { usageStore.reading(for: .grok)?.lastPolledAt }
    var claudeIsLoading: Bool { usageStore.refreshing.contains(.claude) }
    var claudeSnapshot: ProviderSnapshot? { usageStore.reading(for: .claude)?.value }
    var lastError: String? {
        usageStore.reading(for: .claude)?.error ?? claudeAccounts.compactMap(\.lastError).first
    }
    var lastPolledAt: Date? { usageStore.reading(for: .claude)?.lastPolledAt }
    var claudeDiagnostics: ClaudeDiagnostics {
        (usageStore.provider(for: .claude) as? ClaudeProviderAdapter)?.diagnostics
            ?? ClaudeDiagnostics()
    }
    var oauthCredentialIssue: OAuthCredentialIssue? { claudeDiagnostics.credentialIssue }
    var oauthRetryAt: Date? {
        (usageStore.provider(for: .claude) as? ClaudeProviderAdapter)?.retryAt
    }
    var accountOAuthFailures: [String: MultiAccountOAuth.AccountFetchFailure] {
        claudeDiagnostics.accountFailures
    }
    var claudeAccounts: [ProviderAccountSnapshot] {
        (claudeSnapshot?.accounts ?? []).filter {
            $0.id == "claude" || !MeterSettings.disabledAccountKeys.contains($0.id)
        }.map {
            var account = $0
            account.label =
                MeterSettings.accountName(forKey: account.id) ?? account.label.friendlyAccountLabel
            account.plan = MeterSettings.accountPlan(forKey: account.id) ?? account.plan
            return account
        }
    }
    var normalizedSnapshots: [ProviderID: ProviderSnapshot] {
        var values = usageStore.readings.compactMapValues(\.value)
        if let snapshot = values[.claude] {
            values[.claude] = ProviderSnapshot(
                provider: .claude, accounts: claudeAccounts, fetchedAt: snapshot.fetchedAt)
        }
        if let snapshot = values[.codex] {
            values[.codex] = ProviderSnapshot(
                provider: .codex, accounts: codexAccounts, fetchedAt: snapshot.fetchedAt)
        }
        return values
    }

    var mainMeterProvider: MainMeterProvider {
        MeterSettings.resolvedMainMeterProvider()
    }

    private struct MainMeterSourceState {
        let readings: [MainMeterReading]
        let selected: MainMeterReading?
        let isLoading: Bool
        let error: String?
    }

    private var mainMeterSourceState: MainMeterSourceState {
        let provider = mainMeterProvider
        let enabled =
            provider == .claude ? AppSettings.oauthSourceEnabled : AppSettings.codexSourceEnabled
        let loading = provider == .claude ? claudeIsLoading : codexIsLoading
        guard enabled else {
            return MainMeterSourceState(
                readings: [], selected: nil, isLoading: loading,
                error: "\(provider.displayName) is not enabled in Data settings.")
        }
        let accounts = provider == .claude ? claudeAccounts : codexAccounts
        let selected = ProviderAccountSelection.primary(
            from: accounts,
            pinnedAccountID: Self.pinnedAccountID(for: provider), asOf: Date())
        let reading = selected.flatMap { MainMeterReading(account: $0, provider: provider) }
        let error: String?
        if let pin = Self.pinnedAccountID(for: provider) {
            error =
                accounts.first { $0.id == pin }?.lastError
                ?? (!accounts.contains { $0.id == pin }
                    ? "The selected \(provider.displayName) account is no longer configured." : nil)
                ?? (reading == nil
                    ? "The selected \(provider.displayName) account has no usage reading." : nil)
        } else {
            error =
                accounts.compactMap(\.lastError).first
                ?? (reading == nil ? "\(provider.displayName) has no usage reading." : nil)
        }
        return MainMeterSourceState(
            readings: accounts.compactMap { MainMeterReading(account: $0, provider: provider) },
            selected: reading, isLoading: loading, error: error)
    }

    /// All usable readings for the selected provider. Ordering is stable; the
    /// selection policy chooses the nearest or explicitly pinned account.
    var mainMeterReadings: [MainMeterReading] { mainMeterSourceState.readings }

    /// Reading that owns the hero, header timestamp, and specific-window
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
            || MeterSettings.isSnapshotStale(lastPollAt: reading.observedAt)
    }

    var mainMeterLastSuccessfulAt: Date? { mainMeterReading?.observedAt }

    var mainMeterIsLoading: Bool { mainMeterSourceState.isLoading }

    var mainMeterError: String? { mainMeterSourceState.error }

    private static func pinnedAccountID(for provider: MainMeterProvider) -> String? {
        if case .account(let key) = MeterSettings.mainMeterAccountSelection(provider: provider) {
            return key
        }
        return nil
    }

    init() {
        self.usageStore = UsageStore(providers: [
            ClaudeProviderAdapter(configuration: {
                ClaudeConfiguration(
                    mode: UserDefaults.standard.string(forKey: MeterSettings.oauthModeKey) ?? "",
                    configuredDirs: MeterSettings.configuredConfigDirs,
                    disabledKeys: Set(MeterSettings.disabledAccountKeys),
                    thresholds: MeterSettings.currentThresholds())
            }),
            CodexProviderAdapter(configuration: {
                await Task.detached(priority: .utility) {
                    CodexConfiguration(
                        accounts: AppSettings.codexAccounts())
                }.value
            }), CursorProviderAdapter(), GrokProviderAdapter(),
        ])
        self.refreshScheduler = RefreshScheduler(usageStore: usageStore)
        OAuthPipeline.enableRateLimitPersistence()
        UserDefaults.standard.register(defaults: [
            AppSettings.isActiveKey: true
        ])
        self.onboardingIsComplete = UserDefaults.standard.bool(
            forKey: "hasCompletedOnboarding")
        MeterSettings.repairMenuBarWindow()
        let configuredDirs = MeterSettings.configuredConfigDirs
        let claudeProvider = usageStore.provider(for: .claude) as? ClaudeProviderAdapter
        Task.detached(priority: .utility) {
            do {
                try LegacyAttentionHookMigration.runIfNeeded(configuredDirs: configuredDirs)
            } catch {
                MeterLog.logger(.app).error(
                    "Legacy hook cleanup failed: \(error.localizedDescription)")
            }
            do { try LegacyStatuslineMigration.runIfNeeded(configuredDirs: configuredDirs) } catch {
                MeterLog.logger(.app).error(
                    "Legacy statusline cleanup failed: \(error.localizedDescription)")
            }
            do { try await claudeProvider?.importLegacySnapshotIfNeeded() } catch {
                MeterLog.logger(.app).error("Legacy snapshot import failed", error: error)
            }
            do { try LegacyArtifactCleanupMigration.runIfNeeded() } catch {
                MeterLog.logger(.app).error("Obsolete artifact cleanup failed", error: error)
            }
        }
        self.activationDefaults = .standard
        self.ephemeralDefaultsSuiteName = nil
        self.isActive = AppSettings.isActive
        self.hasEnabledDataSource = AppSettings.hasEnabledDataSource
        let appUpdater = AppUpdater(startingUpdater: true)
        self.appUpdater = appUpdater
        appUpdater.appState = self
        observeUsageStore()
        if !onboardingIsComplete, hasExistingUserEvidence {
            onboardingIsComplete = true
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }
        if !onboardingIsComplete {
            Task { [weak self] in
                guard let self,
                    let provider = self.usageStore.provider(for: .claude) as? ClaudeProviderAdapter,
                    await provider.hasPersistedObservation()
                else { return }
                self.completeOnboarding()
            }
        }
        refreshScheduler.update(configuration: refreshConfiguration)
    }

    init(
        usageStore: UsageStore = UsageStore(providers: []),
        onboardingIsComplete: Bool = true
    ) {
        self.usageStore = usageStore
        self.refreshScheduler = RefreshScheduler(
            usageStore: usageStore, powerMonitor: nil)
        self.onboardingIsComplete = onboardingIsComplete
        let suiteName = "ClaudeMeter-AppState-\(UUID().uuidString)"
        self.activationDefaults = UserDefaults(suiteName: suiteName)!
        self.ephemeralDefaultsSuiteName = suiteName
        self.isActive = true
        self.hasEnabledDataSource = true
        let appUpdater = AppUpdater(startingUpdater: false)
        self.appUpdater = appUpdater
        appUpdater.appState = self
        observeUsageStore()
    }

    private func observeUsageStore() {
        usageStoreChanges = usageStore.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    deinit {
        if let ephemeralDefaultsSuiteName {
            UserDefaults(suiteName: ephemeralDefaultsSuiteName)?.removePersistentDomain(
                forName: ephemeralDefaultsSuiteName)
        }
    }

    func checkForUpdates() { appUpdater.checkForUpdates() }

    func refreshNow() { refreshScheduler.refreshNow() }

    func popoverDidOpen() { refreshScheduler.popoverDidOpen() }

    var claudeIsStale: Bool {
        claudeAccounts.contains {
            $0.isStale || MeterSettings.isSnapshotStale(lastPollAt: $0.observedAt)
        }
    }

    var isStale: Bool {
        let cursorStale =
            AppSettings.cursorSourceEnabled
            && cursorSnapshot != nil
            && MeterSettings.isSnapshotStale(lastPollAt: cursorLastPolledAt)
        let claudeStale = claudeIsStale
        return claudeStale || cursorStale
    }

    var cursorIsStale: Bool {
        MeterSettings.isSnapshotStale(lastPollAt: cursorLastPolledAt)
    }

    /// Observation age only. A recent last-good value remains fresh even when
    /// the newest refresh attempt failed; callers can inspect `reading.error`
    /// independently.
    var codexIsStale: Bool {
        codexAccounts.contains {
            $0.observedAt != nil && MeterSettings.isSnapshotStale(lastPollAt: $0.observedAt)
        }
    }

    var grokIsStale: Bool {
        MeterSettings.isSnapshotStale(lastPollAt: grokLastPolledAt)
    }

    func providerEnablementDidChange() {
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        refreshScheduler.update(configuration: refreshConfiguration)
    }

    func codexConfigurationDidChange() {
        objectWillChange.send()
        codexConfiguration = AppSettings.codexAccounts()
        refreshScheduler.refresh([.codex])
    }

    /// A rename changes labels only. It needs no path resolution and no refresh.
    func codexAccountNamesDidChange() {
        objectWillChange.send()
        let names = AppSettings.codexAccountNames
        codexConfiguration = codexConfiguration.map {
            CodexAccount(home: $0.home, isImplicit: $0.isImplicit, customName: names[$0.id])
        }
    }

    func claudeConfigurationDidChange() {
        providerEnablementDidChange()
        refreshScheduler.refresh([.claude])
    }

    private var refreshConfiguration: RefreshConfiguration {
        var enabled: Set<ProviderID> = []
        if AppSettings.oauthSourceEnabled { enabled.insert(.claude) }
        if AppSettings.codexSourceEnabled { enabled.insert(.codex) }
        if AppSettings.cursorSourceEnabled { enabled.insert(.cursor) }
        if AppSettings.grokSourceEnabled { enabled.insert(.grok) }
        return RefreshConfiguration(
            isActive: onboardingIsComplete && isActive, enabledProviders: enabled)
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        activationDefaults.set(active, forKey: AppSettings.isActiveKey)
        isActive = active
        refreshScheduler.update(configuration: refreshConfiguration)
    }

    /// Releases the first-run gate. Onboarding remains application state.
    func completeOnboarding() {
        guard !onboardingIsComplete else { return }
        onboardingIsComplete = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        refreshScheduler.update(configuration: refreshConfiguration)
    }

    /// Existing installs must not see first-run onboarding after an upgrade.
    /// Keychain probes are attributes-only and never read credential contents.
    private var hasExistingUserEvidence: Bool {
        Self.existingUserEvidenceIsPresent(
            snapshotExists: claudeSnapshot != nil,
            automaticOAuthAvailability: OAuthKeychain.credentialAvailability(),
            manualOAuthAvailability: OAuthKeychain.manualCredentialAvailability(),
            cursorStateExists: CursorTokenStore.isStateDBPresent(),
            codexUsageExists: codexAccounts.contains(where: { $0.observedAt != nil }),
            codexConfigurationExists: Self.codexConfigurationExists
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
        codexConfigurationExists: Bool
    ) -> Bool {
        snapshotExists
            || automaticOAuthAvailability == .available
            || manualOAuthAvailability == .available
            || cursorStateExists
            || codexUsageExists
            || codexConfigurationExists
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
        MeterSettings.currentThresholds()
    }

    /// The display name for an account key — the user's override, else a prettified
    /// label — matching how the popover labels accounts (which strips the `claude-`
    /// prefix / maps `claude` → "default" via `ConfigDirDiscovery.label`).
    static func friendlyAccountName(_ key: String) -> String {
        MeterSettings.accountName(forKey: key)
            ?? ConfigDirDiscovery.label(forKey: key).friendlyAccountLabel
    }
}

import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
import Foundation
import Testing

@testable import ClaudeMeter

@MainActor
private final class TestPopoverWindowAdapter: PopoverWindowAdapter {
    struct Animation {
        let source: CGRect
        let target: CGRect
        let completion: @MainActor (PopoverWindowAnimationOutcome) -> Void
    }

    var isVisible = true
    var frame: CGRect?
    var visibleScreenFrame: CGRect? = CGRect(x: 0, y: 0, width: 1_440, height: 720)
    var canAnimate = true
    private(set) var immediateFrames: [CGRect] = []
    private(set) var animations: [Animation] = []
    private(set) var interruptionCount = 0

    init(frame: CGRect = CGRect(x: 100, y: 500, width: 360, height: 220)) {
        self.frame = frame
    }

    func interruptAndCapturePresentation() -> CGRect? {
        interruptionCount += 1
        return frame
    }

    func setFrameImmediately(_ frame: CGRect, display _: Bool) {
        self.frame = frame
        immediateFrames.append(frame)
    }

    func animateFrame(
        to frame: CGRect,
        duration _: TimeInterval,
        completion: @escaping @MainActor (PopoverWindowAnimationOutcome) -> Void
    ) -> Bool {
        guard canAnimate, let source = self.frame else { return false }
        animations.append(Animation(source: source, target: frame, completion: completion))
        return true
    }

    func advanceAnimation(_ index: Int, to frame: CGRect) {
        self.frame = frame
    }

    func completeAnimation(_ index: Int) {
        let animation = animations[index]
        frame = animation.target
        animation.completion(.reachedTarget)
    }

    func deliverCompletion(_ index: Int) {
        animations[index].completion(.reachedTarget)
    }

    func stopAnimation(_ index: Int) {
        animations[index].completion(.stopped)
    }
}

private actor PollRecorder {
    private var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let currentWaiters = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        for waiter in currentWaiters { waiter.continuation.resume() }
    }

    func pollCount() -> Int { count }

    func waitForPoll(_ target: Int = 1) async {
        guard count < target else { return }
        await withCheckedContinuation {
            waiters.append((target: target, continuation: $0))
        }
    }
}

private struct RecordingProvider: UsageProvider {
    let id: ProviderID = .claude
    let recorder: PollRecorder

    func fetch(now: Date, previous: ProviderSnapshot?, refreshID: UUID) async throws
        -> ProviderSnapshot
    {
        await recorder.record()
        return ProviderSnapshot(provider: .claude, accounts: [], fetchedAt: now)
    }
}

@Suite("App logic", .serialized)
struct AppLogicTests {
    private struct CodexDisplayProvider: UsageProvider {
        var id: ProviderID { snapshot.provider }
        let snapshot: ProviderSnapshot
        func fetch(
            now: Date, previous: ProviderSnapshot?, refreshID: UUID
        ) async throws -> ProviderSnapshot { snapshot }
    }

    @MainActor private func recordingStore(_ recorder: PollRecorder) -> UsageStore {
        let store = UsageStore(providers: [RecordingProvider(recorder: recorder)])
        store.setEnabled(.claude, enabled: true)
        return store
    }

    @Test("Codex main meter reads the store, honors exact pins and removes missing homes")
    @MainActor
    func codexStoreSelection() async {
        let defaults = UserDefaults.standard
        let keys = [
            AppSettings.configuredCodexHomesKey, AppSettings.codexAccountNamesKey,
            AppSettings.codexSourceEnabledKey, MeterSettings.mainMeterProviderKey,
            MeterSettings.codexMainMeterAccountKey,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        let homeA = URL(fileURLWithPath: "/test/personal").resolvingSymlinksInPath().path
        let homeB = URL(fileURLWithPath: "/test/work").resolvingSymlinksInPath().path
        defaults.set([homeA, homeB], forKey: AppSettings.configuredCodexHomesKey)
        defaults.set([homeA: "Personal", homeB: "Work"], forKey: AppSettings.codexAccountNamesKey)
        defaults.set(true, forKey: AppSettings.codexSourceEnabledKey)
        defaults.set("codex", forKey: MeterSettings.mainMeterProviderKey)
        defaults.removeObject(forKey: MeterSettings.codexMainMeterAccountKey)
        let now = Date()
        let accounts = [(homeA, 20.0), (homeB, 80.0)].map { id, used in
            ProviderAccountSnapshot(
                id: id, label: "Old name", plan: "Plus",
                windows: [
                    UsageWindow(
                        id: "primary", title: "5h", kind: .session, usedPercent: used,
                        resetAt: now.addingTimeInterval(3600))
                ], observedAt: now)
        }
        let store = UsageStore(providers: [
            CodexDisplayProvider(
                snapshot: ProviderSnapshot(
                    provider: .codex, accounts: accounts, fetchedAt: now))
        ])
        store.setEnabled(.codex, enabled: true)
        let app = AppState(
            usageStore: store, onboardingIsComplete: false)
        await store.refresh([.codex])
        #expect(app.codexAccounts.map(\.label) == ["Personal", "Work"])
        #expect(app.mainMeterReading?.accountID == homeB)
        defaults.set([homeA: "Side"], forKey: AppSettings.codexAccountNamesKey)
        app.codexAccountNamesDidChange()
        #expect(app.codexAccounts.map(\.label) == ["Side", "work"])
        #expect(!store.refreshing.contains(.codex))
        defaults.set(homeA, forKey: MeterSettings.codexMainMeterAccountKey)
        #expect(app.mainMeterReading?.accountID == homeA)
        defaults.set([homeB], forKey: AppSettings.configuredCodexHomesKey)
        app.codexConfigurationDidChange()
        #expect(app.mainMeterReading == nil)
        #expect(app.mainMeterError?.contains("no longer configured") == true)
        #expect(app.codexAccounts.map(\.id) == [homeB])
        AppSettings.codexSourceEnabled = false
        app.providerEnablementDidChange()
        #expect(app.codexAccounts.isEmpty)
        #expect(store.reading(for: .codex) == nil)
    }

    @Test("A temporary Keychain failure does not skip first-run onboarding")
    func temporaryKeychainFailureIsNotExistingUserEvidence() {
        #expect(
            !AppState.existingUserEvidenceIsPresent(
                snapshotExists: false,
                automaticOAuthAvailability: .temporarilyUnavailable,
                manualOAuthAvailability: .temporarilyUnavailable,
                cursorStateExists: false,
                codexUsageExists: false,
                codexConfigurationExists: false))
    }

    @Test("Confirmed OAuth credential presence skips first-run onboarding")
    func availableCredentialIsExistingUserEvidence() {
        #expect(
            AppState.existingUserEvidenceIsPresent(
                snapshotExists: false,
                automaticOAuthAvailability: .available,
                manualOAuthAvailability: .missing,
                cursorStateExists: false,
                codexUsageExists: false,
                codexConfigurationExists: false))
    }

    @MainActor
    @Test("First-run onboarding blocks polling until Get Started")
    func onboardingLifecycle() async throws {
        let defaults = UserDefaults.standard
        let completionKey = "hasCompletedOnboarding"
        let previousCompletion = defaults.object(forKey: completionKey)
        let previousOAuth = defaults.object(forKey: AppSettings.oauthSourceEnabledKey)
        defer {
            if let previousCompletion {
                defaults.set(previousCompletion, forKey: completionKey)
            } else {
                defaults.removeObject(forKey: completionKey)
            }
            if let previousOAuth {
                defaults.set(previousOAuth, forKey: AppSettings.oauthSourceEnabledKey)
            } else {
                defaults.removeObject(forKey: AppSettings.oauthSourceEnabledKey)
            }
        }
        AppSettings.oauthSourceEnabled = true

        let recorder = PollRecorder()
        let appState = AppState(
            usageStore: recordingStore(recorder),
            onboardingIsComplete: false)
        defer { appState.refreshScheduler.stop() }

        appState.providerEnablementDidChange()
        appState.refreshNow()
        await Task.yield()
        let countBeforeStart = await recorder.pollCount()
        #expect(countBeforeStart == 0)

        appState.completeOnboarding()
        try await Timeout.run(seconds: 2) { await recorder.waitForPoll() }
        let countAfterStart = await recorder.pollCount()
        #expect(countAfterStart == 1)
        #expect(defaults.bool(forKey: completionKey))
    }

    @Test("Friendly account labels normalize separators")
    func friendlyAccountLabels() {
        #expect("it-oneone_build".friendlyAccountLabel == "It Oneone Build")
    }

    @MainActor
    @Test("Pausing a test meter preserves the installed meter's activation setting")
    func testMeterActivationIsIsolated() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.isActiveKey)
        let savedActive = previous as? NSNumber
        defer {
            if defaults.object(forKey: AppSettings.isActiveKey) as? NSNumber != savedActive {
                if let previous {
                    defaults.set(previous, forKey: AppSettings.isActiveKey)
                } else {
                    defaults.removeObject(forKey: AppSettings.isActiveKey)
                }
            }
        }
        let state = AppState(usageStore: UsageStore(providers: []))

        state.setActive(false)

        #expect(!state.isActive)
        #expect(defaults.object(forKey: AppSettings.isActiveKey) as? NSNumber == savedActive)
    }

    @Test("Spoken menu-bar text names the window, progression, and overall severity")
    func spokenMenuBarQuota() {
        let now = Date(timeIntervalSince1970: 1_782_269_456)
        let reading = MainMeterReading(
            provider: .codex, accountID: "test", accountLabel: "Test",
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 30),
                currentWeekAllModels: LimitWindow(percentUsed: 96)), observedAt: now)
        for progression in MeterSettings.ProgressionMode.allCases {
            for selection in MeterSettings.MenuBarWindow.allCases {
                let text = MenuBarText.accessibilitySummary(
                    provider: .codex, reading: reading, progression: progression,
                    selection: selection, isActive: true, isStale: false, isLoading: false,
                    severity: .critical, now: now)
                #expect(text.hasPrefix("Claude Meter. Codex."))
                #expect(text.contains("Overall quota is critical."))
                if selection == .fiveHour || selection == .both {
                    #expect(
                        text.contains(
                            progression == .left
                                ? "Session 70 percent left." : "Session 30 percent used."))
                }
                if selection != .fiveHour {
                    #expect(
                        text.contains(
                            progression == .left
                                ? "Weekly 4 percent left." : "Weekly 96 percent used."))
                }
            }
        }
    }

    @Test("Menu-bar speech follows reported resets without predicting depletion")
    func spokenMenuBarReportedReset() {
        let now = Date(timeIntervalSince1970: 1_782_269_456)
        let reset = now.addingTimeInterval(2.5 * 3600)
        let reading = MainMeterReading(
            provider: .claude, accountID: "test", accountLabel: "Test",
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 80, resetsAt: reset)),
            observedAt: now)
        func summary(_ time: Date) -> String {
            MenuBarText.accessibilitySummary(
                provider: .claude, reading: reading, progression: .left, selection: .nearest,
                isActive: true, isStale: false, isLoading: false, severity: .warning, now: time)
        }
        #expect(
            summary(now)
                == "Claude Meter. Claude. Session 20 percent left. Overall quota warning.")
        #expect(
            summary(reset)
                == "Claude Meter. Claude. Session 100 percent left. Overall quota warning.")
    }

    @Test("Spoken menu-bar states never describe stale or paused usage as current")
    func spokenMenuBarStates() {
        let now = Date()
        let reading = MainMeterReading(
            provider: .claude, accountID: "test", accountLabel: "Test",
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 30)), observedAt: now)
        func summary(
            active: Bool = true, stale: Bool = false, loading: Bool = false,
            value: MainMeterReading? = nil, provider: MainMeterProvider = .claude
        ) -> String {
            MenuBarText.accessibilitySummary(
                provider: provider, reading: value, progression: .left, selection: .both,
                isActive: active, isStale: stale, isLoading: loading, severity: .normal, now: now)
        }
        #expect(summary(active: false, value: reading) == "Claude Meter. Claude. Paused.")
        #expect(summary(stale: true, value: reading) == "Claude Meter. Claude. Data is stale.")
        #expect(
            summary(stale: true, loading: true, value: reading)
                == "Claude Meter. Claude. Data is stale. Refreshing.")
        #expect(summary(loading: true) == "Claude Meter. Claude. Loading.")
        #expect(summary() == "Claude Meter. Claude. Usage unavailable.")
        #expect(
            summary(value: reading, provider: .codex) == "Claude Meter. Codex. Usage unavailable.")
        #expect(summary(value: reading).contains("Weekly unavailable."))
        #expect(summary(loading: true, value: reading).hasSuffix("Refreshing."))
    }

    @Test("Native menu-bar accessibility updates without changing visible text")
    @MainActor
    func nativeMenuBarAccessibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [], backing: .buffered, defer: true)
        let container = NSView()
        let button = NSStatusBarButton(frame: .zero)
        let otherButton = NSButton(title: "Other", target: nil, action: nil)
        button.title = "42%"
        container.addSubview(otherButton)
        container.addSubview(button)
        window.contentView = container

        let summary = "Claude Meter. Claude. Session 42 percent left."
        #expect(MenuBarAccessibility.update(summary, in: [window]))
        #expect(button.accessibilityTitle() == summary)
        #expect(button.title == "42%")
        #expect(otherButton.accessibilityTitle() != summary)

        let paused = "Claude Meter. Claude. Paused."
        #expect(MenuBarAccessibility.update(paused, in: [window]))
        #expect(button.accessibilityTitle() == paused)
        #expect(!MenuBarAccessibility.update(paused, in: []))
    }

    @Test("Codex account names prefer a non-empty override")
    func codexDisplayName() {
        let home = URL(fileURLWithPath: "/tmp/codex-work")
        #expect(
            CodexAccount(home: home, isImplicit: false, customName: "Work").displayName == "Work")
        #expect(
            CodexAccount(home: home, isImplicit: false, customName: "  ").displayName
                == "codex-work")
    }

    @Test("Provider reading state keeps value, timestamp, and error coherent")
    func providerReadingState() {
        let date = Date(timeIntervalSince1970: 123)
        let current = ReadingState<String>.current(value: "ok", polledAt: date)
        #expect(current.value == "ok")
        #expect(current.lastPolledAt == date)
        #expect(current.error == nil)
        #expect(!current.isStale)

        let stale = ReadingState<String>.stale(value: "old", polledAt: date, error: "offline")
        #expect(stale.value == "old")
        #expect(stale.lastPolledAt == date)
        #expect(stale.error == "offline")
        #expect(stale.isStale)

        let failed = ReadingState<String>.failed(error: "unavailable", lastPolledAt: date)
        #expect(failed.value == nil)
        #expect(failed.lastPolledAt == date)
        #expect(failed.error == "unavailable")
    }

    @Test("Visual severity uses configured usage thresholds and resolves expired windows")
    func visualSeverityUsesThresholds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = LimitWindow(percentUsed: 75, resetsAt: now.addingTimeInterval(600))
        #expect(window.energyBand(thresholds: .default, asOf: now) == .full)
        #expect(
            window.energyBand(thresholds: UsageThresholds(warning: 70, critical: 90), asOf: now)
                == .low)
        #expect(
            window.energyBand(thresholds: UsageThresholds(warning: 60, critical: 70), asOf: now)
                == .empty)
        #expect(window.displayText(usage: true, asOf: now) == "75%")
        #expect(window.displayText(usage: false, asOf: now) == "25%")
        #expect(window.energyBand(thresholds: .default, asOf: now.addingTimeInterval(601)) == .full)
        #expect(LimitWindow().energyBand(thresholds: .default, asOf: now) == .unknown)
    }

    @Test("Normalized Codex accounts preserve labels, windows and reset credits")
    @MainActor
    func codexMainMeterMapping() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = ProviderAccountSnapshot(
            id: "/test/work", label: "Pi", plan: "Plus",
            windows: [
                UsageWindow(
                    id: "primary", title: "5h", kind: .session,
                    usedPercent: 25, resetAt: now.addingTimeInterval(3600))
            ],
            balances: [
                BalanceItem(
                    id: "usage-resets", title: "Usage limit resets", value: 3,
                    unit: "resets", details: [BalanceDetail(title: "Full reset", expiresAt: now)])
            ],
            observedAt: now)
        let meter = try #require(MainMeterReading(account: account, provider: .codex, now: now))
        #expect(meter.accountLabel == "Pi")
        #expect(meter.plan == "Plus")
        #expect(meter.sessionLabel == "5h")
        #expect(meter.limits.currentSession.percentUsed == 25)
        #expect(meter.observedAt == now)
        let model = try #require(PopoverView.codexAccountModel(account))
        #expect(model.rateLimitResets?.value == 3)
        #expect(model.rateLimitResets?.details?.first?.expiresAt == now)
    }

    @Test("A normalized weekly primary window remains weekly")
    func codexWeeklyPrimaryMapping() throws {
        let now = Date()
        let account = ProviderAccountSnapshot(
            id: "home", label: "Codex",
            windows: [
                UsageWindow(
                    id: "primary", title: "Weekly", kind: .weekly,
                    usedPercent: 18, resetAt: now.addingTimeInterval(3600))
            ], observedAt: now)
        let meter = try #require(MainMeterReading(account: account, provider: .codex, now: now))
        #expect(meter.limits.currentSession.percentUsed == nil)
        #expect(meter.limits.currentWeekAllModels.percentUsed == 18)
        #expect(meter.weeklyLabel == "Weekly")
    }

    @Test("Main Codex account badges preserve both Pro tiers")
    @MainActor
    func codexProPlanBadges() {
        for (raw, expected) in [("prolite", "PRO 5X"), ("pro", "PRO 20X")] {
            let usage = CodexUsage(
                primaryWindow: nil,
                secondaryWindow: nil,
                usageCredits: nil,
                accountEmail: nil,
                plan: raw,
                source: .appServer,
                updatedAt: Date())
            let reading = MainMeterReading(
                provider: .codex,
                accountID: "codex",
                accountLabel: "Codex",
                plan: usage.displayPlanName,
                limits: LimitInfo(currentSession: LimitWindow(percentUsed: 20)),
                observedAt: Date())
            let model = AccountCardModel(mainMeterReading: reading)
            #expect(PlanBadge.style(for: model.plan ?? "").text == expected)
        }
        #expect(PlanBadge.style(for: "Pro").text == "PRO")
    }

    @MainActor
    @Test("Claude selects an exact account pin or the nearest OAuth limit")
    func claudeOAuthAccountSelection() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            MeterSettings.mainMeterProviderKey, MeterSettings.menuBarAccountKey,
            MeterSettings.disabledAccountKeysKey, MeterSettings.accountPlansKey,
            MeterSettings.accountNamesKey, AppSettings.oauthSourceEnabledKey,
        ]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set("claude", forKey: MeterSettings.mainMeterProviderKey)
        defaults.set(true, forKey: AppSettings.oauthSourceEnabledKey)
        defaults.set([], forKey: MeterSettings.disabledAccountKeysKey)
        defaults.set([String: String](), forKey: MeterSettings.accountPlansKey)
        defaults.set([String: String](), forKey: MeterSettings.accountNamesKey)
        defaults.set("nearest", forKey: MeterSettings.menuBarAccountKey)
        let now = Date()
        let accounts = [("claude", 20.0, "Pro", false), ("claude-work", 90.0, "Max", true)].map {
            id, used, plan, stale in
            ProviderAccountSnapshot(
                id: id, label: id, plan: plan,
                windows: [
                    UsageWindow(
                        id: "session", title: "Session", kind: .session, usedPercent: used,
                        resetAt: nil)
                ],
                observedAt: now, isStale: stale)
        }
        let store = UsageStore(providers: [
            CodexDisplayProvider(
                snapshot: ProviderSnapshot(provider: .claude, accounts: accounts, fetchedAt: now))
        ])
        store.setEnabled(.claude, enabled: true)
        let state = AppState(usageStore: store)
        await store.refresh([.claude])
        #expect(state.mainMeterReading?.accountID == "claude-work")
        #expect(state.mainMeterReading?.plan == "Max")
        #expect(state.mainMeterIsStale)
        let normalized = try #require(state.normalizedSnapshots[.claude])
        #expect(normalized.accounts.map(\.id) == ["claude", "claude-work"])
        #expect(normalized.accounts[1].isStale)
        #expect(normalized.fetchedAt == now)
        #expect(
            ProviderAccountSelection.primary(
                from: normalized.accounts, pinnedAccountID: nil, asOf: now)?.id
                == state.mainMeterReading?.accountID)
        defaults.set("claude", forKey: MeterSettings.menuBarAccountKey)
        #expect(state.mainMeterReading?.accountID == "claude")
        #expect(!state.mainMeterIsStale)
        defaults.set("missing", forKey: MeterSettings.menuBarAccountKey)
        #expect(state.mainMeterReading == nil)
        defaults.set("claude-work", forKey: MeterSettings.menuBarAccountKey)
        defaults.set(["claude-work"], forKey: MeterSettings.disabledAccountKeysKey)
        #expect(state.mainMeterReading == nil)
        #expect(state.normalizedSnapshots[.claude]?.accounts.map(\.id) == ["claude"])
        store.setEnabled(.claude, enabled: false)
        #expect(state.normalizedSnapshots[.claude] == nil)
    }

    @Test("Disabling a Claude account preserves its exact main-meter pin")
    func disablingClaudeAccountPreservesPin() {
        let suiteName = "AccountTracking-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("claude-work", forKey: MeterSettings.menuBarAccountKey)

        let disabled = AccountTrackingPolicy.updating(
            disabledKeys: [], accountID: "claude-work", enabled: false)

        #expect(disabled == ["claude-work"])
        #expect(defaults.string(forKey: MeterSettings.menuBarAccountKey) == "claude-work")
    }

    @Test("Account card style applies equally to Claude and Codex")
    func accountCardStyleAppliesToEveryMainProvider() {
        for provider in MainMeterProvider.allCases {
            #expect(
                PopoverView.accountCardStyle(requested: .rings, provider: provider) == .rings)
            #expect(PopoverView.accountCardStyle(requested: .bars, provider: provider) == .bars)
        }
    }

    @Test("Relative update labels clamp external dates")
    func relativeUpdateLabelsClampExternalDates() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(PopoverView.updatedText(lastPollAt: nil, now: now) == "Not yet polled")
        #expect(
            PopoverView.updatedText(lastPollAt: now.addingTimeInterval(60), now: now)
                == "Just now")
        #expect(
            PopoverView.updatedText(
                lastPollAt: Date(timeIntervalSinceReferenceDate: .nan), now: now)
                == "Just now")
        #expect(
            PopoverView.updatedText(
                lastPollAt: Date(
                    timeIntervalSinceReferenceDate: -Double.greatestFiniteMagnitude),
                now: now)
                == "\(Int.max / 60)m ago")

        #expect(
            AdvancedSettingsTab.lastCheckedText(
                date: now.addingTimeInterval(60), now: now)
                == "Last checked just now")
        #expect(
            AdvancedSettingsTab.lastCheckedText(
                date: Date(timeIntervalSinceReferenceDate: .nan), now: now)
                == "Last checked just now")
        #expect(
            AdvancedSettingsTab.lastCheckedText(
                date: Date(
                    timeIntervalSinceReferenceDate: -Double.greatestFiniteMagnitude),
                now: now)
                == "Last checked \(Int.max / 86_400)d ago")
    }

    @Test("Secondary provider badge follows the nearest-limit account")
    func secondaryProviderPlanFollowsNearestLimit() {
        let models = [
            AccountCardModel(
                id: "roomy", label: "Roomy", plan: "Pro", subtitle: nil,
                session: LimitWindow(percentUsed: 10),
                week: LimitWindow(percentUsed: 20), opus: nil),
            AccountCardModel(
                id: "nearest", label: "Nearest", plan: "Max 5x", subtitle: nil,
                session: LimitWindow(percentUsed: 80),
                week: LimitWindow(percentUsed: 70), opus: nil),
        ]

        #expect(
            PopoverView.secondaryProviderPlan(
                from: models,
                asOf: Date(timeIntervalSince1970: 100)) == "Max 5x")
    }

    @Test("Secondary providers do not present unknown limits as full")
    func unknownSecondaryProviderPresentation() {
        let models = [
            AccountCardModel(
                id: "unknown",
                label: "Unknown",
                plan: "Pro",
                subtitle: nil,
                session: LimitWindow(),
                week: LimitWindow(),
                opus: nil)
        ]
        let now = Date(timeIntervalSince1970: 100)

        let presentation = PopoverView.secondaryProviderPresentation(
            from: models,
            showsUsage: false,
            thresholds: UsageThresholds(),
            asOf: now)

        #expect(models[0].bindingLeft(now) == nil)
        #expect(presentation.model == nil)
        #expect(presentation.displayedPercent == nil)
        #expect(presentation.band == .unknown)
        #expect(PopoverView.secondaryProviderPlan(from: models, asOf: now) == nil)
    }

    @Test("Color slider accessibility adjustments use its step and bounds")
    func colorSliderAccessibilityAdjustment() {
        #expect(
            ColorSlider.adjustedValue(
                80,
                direction: .increment,
                range: 50...90,
                step: 5) == 85)
        #expect(
            ColorSlider.adjustedValue(
                90,
                direction: .increment,
                range: 50...90,
                step: 5) == 90)
        #expect(
            ColorSlider.adjustedValue(
                50,
                direction: .decrement,
                range: 50...90,
                step: 5) == 50)
        #expect(
            ColorSlider.adjustedValue(
                .nan,
                direction: .increment,
                range: 50...90,
                step: 5) == 55)
        #expect(ColorSlider.fraction(for: 80, range: 80...80) == 0)
        #expect(ColorSlider.snappedValue(83, range: 50...90, step: 0) == 83)
        #expect(ColorSlider.snappedValue(83, range: 50...90, step: .nan) == 83)
    }

    @Test("Failed secondary provider state remains renderable without claiming cached data")
    func failedSecondaryProviderPresentation() {
        #expect(
            PopoverView.shouldRenderProviderSections(
                hasAnyData: false,
                hasCodexLifecycle: true))
        #expect(
            PopoverView.secondaryProviderDetail(
                hasError: true,
                isStale: false,
                accountCount: 0) == "Refresh failed · no usage data")
        #expect(
            PopoverView.secondaryProviderDetail(
                hasError: true,
                isStale: false,
                accountCount: 1) == "Refresh failed · showing last known data")
    }

    @Test("Chunking preserves order and the final partial chunk")
    func chunking() {
        #expect(Array(1...7).chunked(into: 3) == [[1, 2, 3], [4, 5, 6], [7]])
    }

    @Test("Clipboard diagnostics sanitize the complete text")
    func clipboardDiagnosticsSanitization() {
        let text =
            "Account: user@example.com\nHome: /Users/example/private\nCookie: sessionKey=secret"
        let sanitized = sanitizeDiagnosticsForClipboard(text)

        #expect(!sanitized.contains("user@example.com"))
        #expect(!sanitized.contains("/Users/example/private"))
        #expect(!sanitized.contains("sessionKey=secret"))
        #expect(sanitized.contains("[redacted]"))
    }

    @MainActor
    private func popoverTransitionFixture(
        disclosure: Set<String> = [],
        bodyHeight: CGFloat = 400
    ) -> (PopoverTransitionCoordinator, TestPopoverWindowAdapter) {
        let adapter = TestPopoverWindowAdapter()
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: disclosure,
            windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: disclosure,
                renderSequence: 0,
                height: bodyHeight))
        return (coordinator, adapter)
    }

    @Test("Failed OAuth re-verification keeps an existing connection")
    func failedOAuthReverificationKeepsConnection() {
        #expect(
            OAuthSetupState.afterAutomaticVerificationFailure(
                oauthMode: "auto", message: "retrying") == .connectedAuto)
        #expect(
            OAuthSetupState.afterAutomaticVerificationFailure(
                oauthMode: "", message: "failed") == .error("failed"))
    }

    @Test("Disconnected OAuth setup is immediately actionable")
    func disconnectedOAuthSetupIsActionable() {
        #expect(OAuthSetupState.initial(oauthMode: "") == .promptAuto)
    }

    @Test("OAuth verification cannot apply after source disable")
    func disabledOAuthSourceRejectsVerificationResult() {
        #expect(
            OAuthSetupState.canApplyVerificationResult(
                expectedGeneration: 4,
                currentGeneration: 4,
                sourceIsEnabled: true,
                taskIsCancelled: false))
        #expect(
            !OAuthSetupState.canApplyVerificationResult(
                expectedGeneration: 4,
                currentGeneration: 4,
                sourceIsEnabled: false,
                taskIsCancelled: false))
        #expect(
            !OAuthSetupState.canApplyVerificationResult(
                expectedGeneration: 4,
                currentGeneration: 5,
                sourceIsEnabled: true,
                taskIsCancelled: false))
        #expect(
            !OAuthSetupState.canApplyVerificationResult(
                expectedGeneration: 4,
                currentGeneration: 4,
                sourceIsEnabled: true,
                taskIsCancelled: true))
    }

    @Test("Stale hero does not promise available capacity")
    func staleHeroCopy() {
        let stale = HeroSummary.stale(
            providerName: "Codex", recovery: "Codex data is out of date")
        #expect(stale.title == "Refresh needed")
        #expect(!stale.subtitle.contains("Plenty"))
    }

    @Test("Hero does not call mixed full and unknown accounts all fresh")
    func mixedFullAndUnknownHeroCopy() {
        let now = Date(timeIntervalSince1970: 100)
        let models = [
            AccountCardModel(
                id: "full",
                label: "Full",
                plan: nil,
                subtitle: nil,
                session: LimitWindow(percentUsed: 0),
                week: LimitWindow(percentUsed: 0),
                opus: nil),
            AccountCardModel(
                id: "unknown",
                label: "Unknown",
                plan: nil,
                subtitle: nil,
                session: LimitWindow(),
                week: LimitWindow(),
                opus: nil),
        ]

        let hero = HeroSummary.make(models: models, thresholds: .default, now: now)

        #expect(hero.subtitle == "1 fresh · 1 warming up")
    }

    @Test("Hero calls all known full accounts fresh")
    func allFullHeroCopy() {
        let now = Date(timeIntervalSince1970: 100)
        let models = ["one", "two"].map {
            AccountCardModel(
                id: $0,
                label: $0,
                plan: nil,
                subtitle: nil,
                session: LimitWindow(percentUsed: 0),
                week: LimitWindow(percentUsed: 0),
                opus: nil)
        }

        let hero = HeroSummary.make(models: models, thresholds: .default, now: now)

        #expect(hero.subtitle == "All 2 accounts fresh 🎉")
    }

    @MainActor
    @Test("Popover transition establishes its initial baseline without animation")
    func popoverTransitionBaseline() {
        let (coordinator, adapter) = popoverTransitionFixture(disclosure: ["cursor"])

        #expect(adapter.animations.isEmpty)
        #expect(coordinator.presentation.bodyHeight == 400)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.isSettled)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("Popover disclosure growth preserves the top edge")
    func popoverTransitionGrowth() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        #expect(!coordinator.presentation.revealedCards.contains("cursor"))

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        #expect(adapter.animations.count == 1)
        #expect(adapter.animations[0].source.maxY == adapter.animations[0].target.maxY)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.presentation.bodyHeight == 400)
        #expect(coordinator.presentation.renderedBodyHeight == 500)
        #expect(!coordinator.isSettled)

        adapter.completeAnimation(0)

        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover disclosure shrink hides details before resizing")
    func popoverTransitionShrink() async throws {
        let (coordinator, adapter) = popoverTransitionFixture(
            disclosure: ["cursor"], bodyHeight: 500)
        let sequence = coordinator.desiredDisclosureChanged([])
        #expect(coordinator.presentation.revealedCards.isEmpty)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: [], renderSequence: sequence, height: 400))
        #expect(coordinator.presentation.bodyHeight == 400)
        for _ in 0..<100 where adapter.animations.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }

        let animation = try #require(adapter.animations.first)
        #expect(animation.source.maxY == animation.target.maxY)
        adapter.completeAnimation(0)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover card switching derives geometry from the replacement")
    func popoverTransitionReplacement() {
        let (coordinator, adapter) = popoverTransitionFixture(disclosure: ["cursor"])
        let sequence = coordinator.desiredDisclosureChanged(["codex:a"])
        #expect(coordinator.presentation.revealedCards.isEmpty)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["codex:a"], renderSequence: sequence, height: 400))

        #expect(adapter.animations.isEmpty)
        #expect(coordinator.presentation.revealedCards == ["codex:a"])
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Equal-height replacement preserves a moved menu-item anchor")
    func popoverTransitionEqualHeightFollowsMovedMenuItem() {
        let (coordinator, adapter) = popoverTransitionFixture(disclosure: ["cursor"])
        adapter.frame?.origin.x = 200

        let sequence = coordinator.desiredDisclosureChanged(["codex:a"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["codex:a"], renderSequence: sequence, height: 400))

        #expect(adapter.animations.isEmpty)
        #expect(adapter.frame?.minX == 200)
        #expect(adapter.frame?.maxY == 720)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover transition rejects an old equal semantic render")
    func popoverTransitionRejectsOldMeasurement() {
        let (coordinator, adapter) = popoverTransitionFixture()
        _ = coordinator.desiredDisclosureChanged(["cursor"])
        let latestSequence = coordinator.desiredDisclosureChanged([])

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 600))
        #expect(adapter.animations.isEmpty)
        #expect(coordinator.presentation.bodyHeight == 400)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: [], renderSequence: latestSequence, height: 400))
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover same-set reconciliation interrupts disclosure motion")
    func popoverTransitionReconciliation() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        #expect(adapter.animations.count == 1)

        adapter.advanceAnimation(
            0, to: CGRect(x: 100, y: 170, width: 360, height: 550))
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 550))

        #expect(coordinator.presentation.bodyHeight == 550)
        #expect(coordinator.isSettled)
        let settledFrame = adapter.frame
        adapter.deliverCompletion(0)
        #expect(adapter.frame == settledFrame)
        #expect(coordinator.presentation.bodyHeight == 550)
    }

    @MainActor
    @Test("Popover transition ignores sub-tolerance measurement noise")
    func popoverTransitionTolerance() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500.5))

        #expect(adapter.animations.count == 1)
        #expect(coordinator.presentation.bodyHeight == 400)
    }

    @MainActor
    @Test("Popover interruption retargets from the captured visible frame")
    func popoverTransitionInterruption() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let firstSequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: firstSequence, height: 500))
        let partial = CGRect(x: 100, y: 170, width: 360, height: 550)
        adapter.advanceAnimation(0, to: partial)

        let secondSequence = coordinator.desiredDisclosureChanged(["cursor", "codex:a"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor", "codex:a"],
                renderSequence: secondSequence,
                height: 600))

        #expect(adapter.animations.count == 2)
        #expect(adapter.animations[1].source == partial)
        adapter.deliverCompletion(0)
        #expect(coordinator.presentation.bodyHeight == 400)
        adapter.completeAnimation(1)
        #expect(coordinator.presentation.bodyHeight == 600)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Hidden popover changes coalesce and reattach immediately")
    func popoverTransitionHiddenLifecycle() {
        let (coordinator, adapter) = popoverTransitionFixture()
        coordinator.visibilityChanged(false)
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        #expect(adapter.animations.isEmpty)
        #expect(coordinator.isQuiescent)
        #expect(coordinator.presentation.revealedCards == ["cursor"])

        coordinator.visibilityChanged(true)
        #expect(adapter.animations.isEmpty)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("A transient lower-left reattachment cannot replace the menu-bar anchor")
    func popoverTransitionRejectsLowerLeftReattachment() throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        let anchoredFrame = try #require(adapter.frame)

        coordinator.visibilityChanged(false)
        adapter.frame = CGRect(
            x: 0,
            y: 0,
            width: anchoredFrame.width,
            height: anchoredFrame.height)
        coordinator.visibilityChanged(true)

        #expect(adapter.frame?.minX == anchoredFrame.minX)
        #expect(adapter.frame?.maxY == anchoredFrame.maxY)
    }

    @MainActor
    @Test("A stale anchor cannot cross to a side-by-side display")
    func popoverTransitionRejectsAnchorFromAnotherScreen() async throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        let initialFrameCount = adapter.immediateFrames.count
        coordinator.visibilityChanged(false)
        adapter.visibleScreenFrame = CGRect(x: 1_440, y: 0, width: 1_440, height: 720)
        adapter.frame = CGRect(x: 1_440, y: 0, width: 360, height: 220)

        coordinator.visibilityChanged(true)
        #expect(adapter.immediateFrames.count == initialFrameCount)
        #expect(coordinator.isQuiescent)

        adapter.frame = CGRect(x: 1_500, y: 500, width: 360, height: 220)
        for _ in 0..<100 where !coordinator.isSettled {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(coordinator.isSettled)
        #expect(adapter.frame?.minX == 1_500)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("A transient origin cannot become an animation source")
    func popoverTransitionRejectsLowerLeftAnimationSource() throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        let anchoredFrame = try #require(adapter.frame)
        adapter.frame = CGRect(
            x: 0,
            y: 0,
            width: anchoredFrame.width,
            height: anchoredFrame.height)

        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        let animation = try #require(adapter.animations.first)
        #expect(animation.source.minX == anchoredFrame.minX)
        #expect(animation.source.maxY == anchoredFrame.maxY)
    }

    @MainActor
    @Test("A valid moved anchor becomes the animation target")
    func popoverTransitionFollowsMovedMenuItem() throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        adapter.frame?.origin.x = 200

        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        let animation = try #require(adapter.animations.first)
        #expect(animation.source.minX == 200)
        #expect(animation.target.minX == 200)
        #expect(animation.target.maxY == 720)
    }

    @MainActor
    @Test("Measurement-time anchor supersedes the disclosure-time capture")
    func popoverTransitionUsesLatestAnchorBeforeAnimation() throws {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        adapter.frame?.origin.x = 200

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        let animation = try #require(adapter.animations.first)
        #expect(animation.source.minX == 200)
        #expect(animation.target.minX == 200)
    }

    @MainActor
    @Test("Animation completion adopts the actual moved anchor")
    func popoverTransitionCompletionFollowsMovedMenuItem() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        adapter.advanceAnimation(
            0, to: CGRect(x: 200, y: 120, width: 360, height: 600))

        adapter.deliverCompletion(0)

        #expect(adapter.frame?.minX == 200)
        #expect(adapter.frame?.maxY == 720)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("An initial transient origin waits for AppKit's menu-bar placement")
    func popoverTransitionWaitsForInitialAnchor() async throws {
        let adapter = TestPopoverWindowAdapter(
            frame: CGRect(x: 0, y: 0, width: 360, height: 220))
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 400))

        #expect(adapter.immediateFrames.isEmpty)
        #expect(coordinator.isQuiescent)

        adapter.frame = CGRect(x: 100, y: 500, width: 360, height: 220)
        for _ in 0..<100 where !coordinator.isSettled {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(coordinator.isSettled)
        #expect(adapter.frame?.minX == 100)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("Window readiness after visibility resumes reconciliation")
    func popoverTransitionWaitsForVisibleWindow() async throws {
        let adapter = TestPopoverWindowAdapter()
        adapter.isVisible = false
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 400))
        #expect(coordinator.isQuiescent)

        adapter.isVisible = true
        for _ in 0..<100 where !coordinator.isSettled {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(coordinator.isSettled)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("A delayed AppKit placement remains eligible for reconciliation")
    func popoverTransitionWaitsBeyondInitialRetryWindow() async throws {
        let adapter = TestPopoverWindowAdapter(
            frame: CGRect(x: 0, y: 0, width: 360, height: 220))
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 400))

        try await Task.sleep(for: .milliseconds(180))
        #expect(coordinator.isQuiescent)
        adapter.frame = CGRect(x: 100, y: 500, width: 360, height: 220)
        try await Task.sleep(for: .milliseconds(120))

        #expect(coordinator.isSettled)
        #expect(adapter.frame?.maxY == 720)
    }

    @MainActor
    @Test("Hiding during growth preserves the fixed header baseline")
    func popoverTransitionHideDuringGrowth() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        adapter.advanceAnimation(
            0, to: CGRect(x: 100, y: 170, width: 360, height: 550))

        coordinator.visibilityChanged(false)
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.isQuiescent)
        coordinator.visibilityChanged(true)

        #expect(adapter.frame?.height == 600)
        #expect(adapter.frame?.maxY == 720)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Invalid geometry during growth restores the latest valid target")
    func popoverTransitionInvalidMeasurementDuringGrowth() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        adapter.advanceAnimation(
            0, to: CGRect(x: 100, y: 170, width: 360, height: 550))

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: .nan))

        #expect(adapter.frame?.height == 600)
        #expect(adapter.frame?.maxY == 720)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Hidden reattachment waits for a current correlated measurement")
    func popoverTransitionReattachmentRejectsOldMeasurement() {
        let (coordinator, adapter) = popoverTransitionFixture()
        coordinator.visibilityChanged(false)
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])

        coordinator.visibilityChanged(true)
        #expect(coordinator.isQuiescent)
        #expect(!coordinator.isSettled)
        #expect(adapter.animations.isEmpty)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        #expect(coordinator.isSettled)
        #expect(coordinator.presentation.bodyHeight == 500)
    }

    @MainActor
    @Test("Reduce Motion waits for matching layout before revealing")
    func popoverTransitionReduceMotionAwaitsMeasurement() {
        let (coordinator, _) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.reduceMotionChanged(true)

        #expect(!coordinator.presentation.revealedCards.contains("cursor"))
        #expect(coordinator.presentation.bodyHeight == 400)
        #expect(!coordinator.isSettled)

        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Reduce Motion settles disclosure without an animation")
    func popoverTransitionReduceMotion() {
        let (coordinator, adapter) = popoverTransitionFixture()
        coordinator.reduceMotionChanged(true)
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        #expect(adapter.animations.isEmpty)
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Popover body height respects the attached screen cap")
    func popoverTransitionHeightCap() {
        let adapter = TestPopoverWindowAdapter()
        adapter.visibleScreenFrame = CGRect(x: 0, y: 20, width: 1_440, height: 700)
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 1_000))

        #expect(coordinator.presentation.bodyHeight == 628)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("A live screen change reapplies the raw measurement to the new cap")
    func popoverTransitionReappliesScreenCap() {
        let adapter = TestPopoverWindowAdapter(
            frame: CGRect(x: 100, y: 680, width: 360, height: 220))
        adapter.visibleScreenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let coordinator = PopoverTransitionCoordinator(
            initialDesiredDisclosure: [], windowAdapter: adapter)
        coordinator.visibilityChanged(true)
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(disclosure: [], renderSequence: 0, height: 1_000))
        #expect(coordinator.presentation.bodyHeight == 828)

        adapter.visibleScreenFrame = CGRect(x: 0, y: 0, width: 1_200, height: 700)
        adapter.frame = CGRect(x: 100, y: 480, width: 360, height: 220)
        coordinator.windowScreenChanged()

        #expect(coordinator.presentation.bodyHeight == 628)
        #expect(adapter.frame?.maxY == 700)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("A stopped window animation settles through the immediate path")
    func popoverTransitionStoppedAnimation() {
        let (coordinator, adapter) = popoverTransitionFixture()
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))
        adapter.advanceAnimation(
            0, to: CGRect(x: 200, y: 170, width: 360, height: 550))

        adapter.stopAnimation(0)

        #expect(adapter.frame?.minX == 200)
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.presentation.renderedBodyHeight == 500)
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Unavailable window animation falls back to immediate settlement")
    func popoverTransitionAnimationFallback() {
        let (coordinator, adapter) = popoverTransitionFixture()
        adapter.frame?.origin.x = 200
        adapter.canAnimate = false
        let sequence = coordinator.desiredDisclosureChanged(["cursor"])
        coordinator.bodyMeasured(
            CorrelatedBodyMeasurement(
                disclosure: ["cursor"], renderSequence: sequence, height: 500))

        #expect(adapter.animations.isEmpty)
        #expect(adapter.frame?.minX == 200)
        #expect(coordinator.presentation.bodyHeight == 500)
        #expect(coordinator.presentation.revealedCards == ["cursor"])
        #expect(coordinator.isSettled)
    }

    @MainActor
    @Test("Window attachment does not publish during the view update")
    func popoverWindowCaptureDefersPublication() async {
        let view = PopoverWindowCaptureView()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        var received: [ObjectIdentifier?] = []
        view.windowChanged = { received.append($0.map(ObjectIdentifier.init)) }
        window.contentView?.addSubview(view)
        #expect(received.isEmpty)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(received == [ObjectIdentifier(window)])
        view.removeFromSuperview()
    }

    @MainActor
    @Test("Deferred window capture uses the latest attachment and callback")
    func popoverWindowCaptureRejectsOldAttachment() async {
        let view = PopoverWindowCaptureView()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        var oldCalls = 0
        var received: [ObjectIdentifier?] = []
        view.windowChanged = { _ in oldCalls += 1 }
        window.contentView?.addSubview(view)
        view.removeFromSuperview()
        view.windowChanged = { received.append($0.map(ObjectIdentifier.init)) }
        #expect(oldCalls == 0)
        #expect(received.isEmpty)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(oldCalls == 0)
        #expect(received == [nil])
    }

}

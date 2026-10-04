import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import MeterApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppModelTests {
    private let claude = FakeUsageProvider(.claude)
    private let codex = FakeUsageProvider(.codex)
    private let grok = FakeUsageProvider(.grok)
    private let logFile = LogFile.temporary()

    private func makeModel(
        _ settings: Settings = Settings(), display: FakeDisplay? = nil
    ) -> AppModel {
        claude.enqueue(.sample(.claude, account: "claude", observedAt: Date()))
        codex.enqueue(.sample(.codex, observedAt: Date()))
        grok.enqueue(.sample(.grok, observedAt: Date()))
        let defaults = MemoryStore()
        defaults.set(SettingsCodec.encode(settings), forKey: SettingsStore.storageKey)
        let store = UsageStore(providers: [claude, codex, grok])
        let scheduler = RefreshScheduler(
            store: store, display: display,
            sleep: { _ in
                try await Task.sleep(for: .seconds(3_600))
            })
        return AppModel(
            settings: SettingsStore(store: defaults), usage: store, scheduler: scheduler,
            updater: DisabledUpdater(), logFile: logFile)
    }

    /// Settings onboarded, with Claude connected unless `connected` is false.
    private func active(connected: Bool = true) -> Settings {
        var settings = Settings()
        settings.hasCompletedOnboarding = true
        settings.claude.connection = connected ? .automatic : .off
        return settings
    }

    @Test func theLogSettingDrivesTheInjectedLogFile() async {
        var settings = active()
        settings.writesLogFile = true
        let model = makeModel(settings)
        await model.start(archive: nil)
        #expect(logFile.isEnabled)
        model.settings.update { $0.writesLogFile = false }
        #expect(!logFile.isEnabled)
    }

    @Test func completingOnboardingStartsRefreshing() async {
        var settings = Settings()
        settings.claude.connection = .automatic
        let model = makeModel(settings)
        await model.start(archive: nil)
        await model.scheduler?.waitForWork()
        #expect(claude.fetchCount == 0)
        model.completeOnboarding()
        await model.scheduler?.waitForWork()
        #expect(claude.fetchCount == 1)
        #expect(model.usage.readings[.claude] != nil)
    }

    @Test func unconnectedClaudeNeitherRefreshesNorShows() async {
        var settings = active(connected: false)
        settings.grok.isEnabled = true
        let model = makeModel(settings)
        await model.start(archive: nil)
        await model.scheduler?.waitForWork()
        #expect(model.usage.readings[.grok] != nil)
        #expect(claude.fetchCount == 0)
        #expect(model.usage.readings[.claude] == nil)
    }

    @Test func connectingClaudeRefreshesItAndDisconnectingRemovesIt() async {
        let model = makeModel(active(connected: false))
        await model.start(archive: nil)
        model.settings.update { $0.claude.connection = .automatic }
        await model.scheduler?.waitForWork()
        #expect(model.usage.readings[.claude] != nil)
        #expect(claude.fetchCount == 1)
        model.settings.update { $0.claude.connection = .off }
        #expect(model.usage.readings[.claude] == nil)
    }

    @Test func enablingAProviderRefreshesItAndDisablingClearsIt() async {
        let model = makeModel(active())
        await model.start(archive: nil)
        await model.scheduler?.waitForWork()
        model.settings.update { $0.grok.isEnabled = true }
        await model.scheduler?.waitForWork()
        #expect(grok.fetchCount == 1)
        #expect(claude.fetchCount == 1)
        #expect(model.usage.readings[.grok] != nil)
        model.settings.update { $0.grok.isEnabled = false }
        #expect(model.usage.readings[.grok] == nil)
    }

    @Test func codexHomesChangeRefreshesOnlyCodex() async {
        var settings = active()
        settings.codex.isEnabled = true
        let model = makeModel(settings)
        await model.start(archive: nil)
        await model.scheduler?.waitForWork()
        #expect(codex.fetchCount == 1)
        model.settings.update { $0.codex.extraHomes = ["/work"] }
        await model.scheduler?.waitForWork()
        #expect(codex.fetchCount == 2)
        #expect(claude.fetchCount == 1)
    }

    @Test func claudeAccountChangeWhilePausedRemovesTheOldLogin() async {
        let model = makeModel(active())
        await model.start(archive: nil)
        await model.scheduler?.waitForWork()
        #expect(model.usage.readings[.claude] != nil)
        model.settings.update { $0.isPaused = true }
        claude.setReconcile { _ in nil }
        model.settings.update { $0.claude.disabledAccounts = ["claude-work"] }
        await model.scheduler?.waitForWork()
        #expect(model.usage.readings[.claude] == nil)
        #expect(claude.fetchCount == 1)
    }

    @Test func diagnosticsTextJoinsSections() {
        let report = DiagnosticsReport(sections: [
            .init(title: "App", facts: [DiagnosticFact("Version", "4.0.0 (400)")]),
            .init(title: "Readings", facts: [DiagnosticFact("Claude", "none")]),
        ])
        #expect(report.text == "App\nVersion: 4.0.0 (400)\n\nReadings\nClaude: none")
    }

    @Test func startWhilePausedRestoresAndReconcilesWithoutRefreshing() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.path("readings.json")
        let writer = ReadingArchive(file: file)
        writer.record(.sample(.claude, account: "claude"), for: .claude)
        writer.record(.sample(.grok), for: .grok)
        writer.flush()

        var settings = Settings()
        settings.hasCompletedOnboarding = true
        settings.isPaused = true
        settings.claude.connection = .automatic
        let model = makeModel(settings)
        // The Claude login changed while the app was closed.
        claude.setReconcile { _ in nil }
        await model.start(archive: ReadingArchive(file: file))
        #expect(model.usage.readings[.claude] == nil)
        // Grok is off, so its saved reading is not restored.
        #expect(model.usage.readings[.grok] == nil)
        #expect(claude.fetchCount == 0)
    }

    @Test func startWithTheDisplayAsleepReconcilesWithoutRefreshing() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.path("readings.json")
        let writer = ReadingArchive(file: file)
        writer.record(.sample(.claude, account: "claude"), for: .claude)
        writer.flush()

        let display = FakeDisplay()
        display.isDisplayAsleep = true
        let model = makeModel(active(), display: display)
        // The Claude login changed while the app was closed.
        claude.setReconcile { _ in nil }
        await model.start(archive: ReadingArchive(file: file))
        #expect(model.usage.readings[.claude] == nil)
        #expect(claude.fetchCount == 0)
    }

    @Test func movingACardToTheTopPinsItsAccount() {
        let model = makeModel()
        let visible: [CardID] = [.account(.claude, "a"), .account(.codex, "b")]
        #expect(model.moveCard(.account(.codex, "b"), to: 0, visible: visible))
        #expect(model.settings.settings.menuBar.provider == .codex)
        #expect(model.settings.settings.menuBar.pinnedAccounts[.codex] == "b")
        #expect(
            model.settings.settings.cards.order == [.account(.codex, "b"), .account(.claude, "a")])
    }

    @Test func droppingAFirstCodexCardInPlaceMakesItTheMainMeter() {
        var settings = Settings()
        settings.claude.connection = .automatic
        settings.codex.isEnabled = true
        let model = makeModel(settings)
        // Claude is in use but has no reading, so the Codex card is first without being main.
        let visible: [CardID] = [.account(.codex, "/h")]
        #expect(model.moveCard(.account(.codex, "/h"), to: 0, visible: visible))
        #expect(model.settings.settings.menuBar.provider == .codex)
        #expect(model.settings.settings.menuBar.pinnedAccounts[.codex] == "/h")
    }

    @Test func aMoveBelowTheTopKeepsTheMenuBarAndAMissingPin() {
        var settings = active()
        settings.codex.isEnabled = true
        settings.grok.isEnabled = true
        settings.menuBar.pinnedAccounts[.claude] = "gone"
        let model = makeModel(settings)
        // The pinned Claude account has no card, so the Codex card is first but not main.
        let visible: [CardID] = [
            .account(.codex, "/h"), .account(.claude, "a"), .account(.grok, .default),
        ]
        #expect(model.moveCard(.account(.grok, .default), to: 1, visible: visible))
        #expect(model.settings.settings.menuBar.provider == .claude)
        #expect(model.settings.settings.menuBar.pinnedAccounts == [.claude: "gone"])
    }

    @Test func movesThatChangeNothingAreNotRefusals() {
        let model = makeModel()
        let visible: [CardID] = [.account(.cursor, .default), .account(.claude, "a")]
        #expect(model.moveCard(.account(.claude, "a"), to: 1, visible: visible))
        #expect(model.settings.settings.cards.order.isEmpty)
    }

    @Test func refusedMovesChangeNothing() {
        let model = makeModel()
        let visible: [CardID] = [.account(.claude, "a"), .account(.cursor, .default)]
        #expect(!model.moveCard(.account(.cursor, .default), to: 0, visible: visible))
        #expect(model.settings.settings.cards.order.isEmpty)
    }

    @Test func automaticOrderClearsOrderAndPins() {
        let model = makeModel()
        model.settings.update {
            $0.cards.order = [.account(.claude, "a")]
            $0.menuBar.pinnedAccounts = [.claude: "a"]
        }
        model.useAutomaticCardOrder()
        #expect(model.settings.settings.cards.order.isEmpty)
        #expect(model.settings.settings.menuBar.pinnedAccounts.isEmpty)
    }

    @Test func togglingACardFlipsItsDisclosure() {
        let model = makeModel()
        model.toggleCard(.account(.grok, .default))
        #expect(model.settings.settings.cards.expanded == [.account(.grok, .default)])
        model.toggleCard(.account(.grok, .default))
        #expect(model.settings.settings.cards.expanded.isEmpty)
    }

    @Test func previewModelHasReadings() {
        let model = AppModel.preview()
        guard case .accounts(let accounts) = model.popoverModel(at: Date()).content else {
            Issue.record("Expected accounts")
            return
        }
        #expect(accounts.cards.count >= 3)
    }
}

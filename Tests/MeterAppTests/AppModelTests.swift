import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import MeterApp

@MainActor
@Suite(.timeLimit(.minutes(1))) final class AppModelTests {
    private let claude = FakeUsageProvider(.claude)
    private let codex = FakeUsageProvider(.codex)
    private let grok = FakeUsageProvider(.grok)
    /// Holds the log file, and is removed after each test.
    private let directory: TemporaryDirectory
    private let logFile: LogFile

    init() throws {
        directory = try TemporaryDirectory()
        logFile = LogFile(directory: directory.path("Logs"))
    }

    deinit {
        directory.remove()
    }

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

    /// Writes a saved Claude reading to the archive in the test folder.
    private func archive(_ usage: ProviderUsage) -> ReadingArchive {
        let file = directory.path("readings.json")
        let writer = ReadingArchive(file: file)
        writer.record(usage, for: .claude)
        writer.flush()
        return ReadingArchive(file: file)
    }

    /// Records the `previous` value of each Claude reconcile, and keeps it unchanged.
    private func recordReconciles() -> Locked<[ProviderUsage?]> {
        let received = Locked<[ProviderUsage?]>([])
        claude.setReconcile { previous in
            received.withLock { $0.append(previous) }
            return previous
        }
        return received
    }

    @Test func startShowsTheSavedReadingUntilARefresh() async throws {
        let saved = ProviderUsage.sample(.claude, account: "claude")
        var settings = active()
        settings.isPaused = true
        let model = makeModel(settings)
        let received = recordReconciles()
        await model.start(archive: archive(saved))
        #expect(received.value == [saved])
        #expect(model.usage.readings[.claude] == .current(saved, observedAt: .reference()))
        #expect(claude.fetchCount == 0)
        let meter = MainMeter(model.context(at: .reference()))
        #expect(meter.selected?.id == "claude")
    }

    /// The archive left out the pinned account, because its owner came from a credential.
    /// While paused, the saved reading shows and the pin waits; the first refresh decides
    /// (review R4-A-01).
    @Test func aPinThatTheSavedReadingLacksWaitsForTheFirstRefresh() async throws {
        var settings = active()
        settings.isPaused = true
        settings.menuBar.pinnedAccounts[.claude] = "work"
        let model = makeModel(settings)
        await model.start(archive: archive(.sample(.claude, account: "claude")))
        let paused = MainMeter(model.context(at: .reference()))
        #expect(paused.issue?.message == "Claude has no usage reading yet.")
        #expect(!paused.hasFailure)

        model.settings.update { $0.isPaused = false }
        await model.scheduler?.waitForWork()
        #expect(claude.fetchCount == 1)
        let refreshed = MainMeter(model.context(at: Date()))
        #expect(refreshed.issue?.message == "The selected Claude account is no longer configured.")
        #expect(refreshed.hasFailure)
    }

    /// The first refresh starts from the saved reading, so a provider can keep it as stale
    /// when the request fails.
    @Test func theFirstRefreshReconcilesTheSavedReading() async throws {
        let saved = ProviderUsage.sample(.claude, account: "claude")
        let model = makeModel(active())
        let received = recordReconciles()
        await model.start(archive: archive(saved))
        await model.scheduler?.waitForWork()
        #expect(received.value == [saved])
        #expect(claude.fetchCount == 1)
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

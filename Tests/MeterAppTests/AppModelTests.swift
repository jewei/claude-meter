import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderClaude
import Testing

@testable import MeterApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppModelTests {
    private let claude = FakeUsageProvider(.claude)
    private let grok = FakeUsageProvider(.grok)

    private func makeModel(_ settings: Settings = Settings()) -> AppModel {
        claude.enqueue(.sample(.claude, account: "claude", observedAt: Date()))
        grok.enqueue(.sample(.grok, observedAt: Date()))
        let defaults = MemoryStore()
        defaults.set(SettingsCodec.encode(settings), forKey: SettingsStore.storageKey)
        let store = UsageStore(providers: [claude, grok])
        let scheduler = RefreshScheduler(
            store: store, display: nil,
            sleep: { _ in
                try await Task.sleep(for: .seconds(3_600))
            })
        return AppModel(
            settings: SettingsStore(store: defaults), usage: store, scheduler: scheduler,
            updater: DisabledUpdater())
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func completingOnboardingStartsRefreshing() async {
        var settings = Settings()
        settings.claude.connection = .automatic
        let model = makeModel(settings)
        await model.start(archive: nil)
        await settle()
        #expect(claude.fetchCount == 0)
        model.completeOnboarding()
        #expect(await waitUntil { model.usage.readings[.claude] != nil })
        #expect(claude.fetchCount == 1)
    }

    @Test func unconnectedClaudeNeitherRefreshesNorShows() async {
        var settings = Settings()
        settings.hasCompletedOnboarding = true
        settings.grok.isEnabled = true
        let model = makeModel(settings)
        await model.start(archive: nil)
        #expect(await waitUntil { model.usage.readings[.grok] != nil })
        #expect(claude.fetchCount == 0)
        #expect(model.usage.readings[.claude] == nil)
    }

    @Test func connectingClaudeRefreshesItAndDisconnectingRemovesIt() async {
        var settings = Settings()
        settings.hasCompletedOnboarding = true
        let model = makeModel(settings)
        await model.start(archive: nil)
        model.settings.update { $0.claude.connection = .automatic }
        #expect(await waitUntil { model.usage.readings[.claude] != nil })
        #expect(claude.fetchCount == 1)
        model.settings.update { $0.claude.connection = .off }
        #expect(model.usage.readings[.claude] == nil)
    }

    @Test func enablingAProviderRefreshesItAndDisablingClearsIt() async {
        var settings = Settings()
        settings.hasCompletedOnboarding = true
        let model = makeModel(settings)
        await model.start(archive: nil)
        model.settings.update { $0.grok.isEnabled = true }
        await settle()
        #expect(grok.fetchCount == 1)
        #expect(model.usage.readings[.grok] != nil)
        model.settings.update { $0.grok.isEnabled = false }
        #expect(model.usage.readings[.grok] == nil)
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

    @Test func movesThatChangeNothingAreNotRefusals() {
        let model = makeModel()
        let visible: [CardID] = [.account(.cursor, .default), .account(.claude, "a")]
        #expect(model.moveCard(.account(.claude, "a"), to: 1, visible: visible))
        #expect(model.settings.settings.cards.order.isEmpty)
    }

    @Test func claudeHistoryReadsOnlyFoldersWithACard() {
        let accounts = [
            ClaudeAccount(
                id: "claude", name: "default", directory: URL(fileURLWithPath: "/c"),
                isDefault: true, isEnabled: true),
            ClaudeAccount(
                id: "claude-work", name: "work", directory: URL(fileURLWithPath: "/w"),
                isDefault: false, isEnabled: true),
            ClaudeAccount(
                id: "claude-old", name: "old", directory: URL(fileURLWithPath: "/o"),
                isDefault: false, isEnabled: false),
        ]
        #expect(LiveProviders.claudeHistoryRoots(accounts, connection: .off).isEmpty)
        #expect(
            LiveProviders.claudeHistoryRoots(accounts, connection: .manual).map(\.account)
                == ["claude"])
        #expect(
            LiveProviders.claudeHistoryRoots(accounts, connection: .automatic).map(\.account)
                == ["claude", "claude-work"])
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

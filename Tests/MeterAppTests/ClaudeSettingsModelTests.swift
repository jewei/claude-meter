import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderClaude
import Testing

@testable import MeterApp

@MainActor
@Suite(.timeLimit(.minutes(1))) final class ClaudeSettingsModelTests {
    private let home: TemporaryDirectory
    private let keychain = FakeKeychain()
    private let gate = Gate()
    private let status = Locked(200)
    private let settings = SettingsStore(store: MemoryStore())
    private let usage = UsageStore(providers: [])
    private let model: ClaudeSettingsModel
    private var credentialChanges = 0

    private static let manualService = AppIdentity.keychainService("claude-oauth")

    init() throws {
        home = try TemporaryDirectory()
        try home.write("{}", to: ".claude/settings.json")
        let gate = gate
        let status = status
        let http = FakeHTTPClient { _ in
            await gate.wait()
            return .json(status.value, #"{"five_hour":{"utilization":10}}"#)
        }
        let settings = settings
        let provider = ClaudeProvider(
            configuration: { @MainActor in settings.claudeConfiguration }, keychain: keychain,
            http: http, store: MemoryStore(), home: home.url)
        model = ClaudeSettingsModel(settings: settings, usage: usage, provider: provider)
        model.onCredentialsChange = { [weak self] in self?.credentialChanges += 1 }
    }

    deinit {
        home.remove()
    }

    private func storeClaudeCodeLogin() {
        let expiry = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1000)
        keychain.store(
            #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":\#(expiry)}}"#,
            service: "Claude Code-credentials", account: NSUserName(), modifiedAt: Date())
    }

    private func connectManually(_ token: String) async -> Bool {
        await model.connectManually(
            accessToken: token, refreshToken: nil, expiresAt: Date().addingTimeInterval(3_600))
    }

    private var manualItem: String? {
        keychain.storedPassword(service: Self.manualService, account: "manual")
    }

    // MARK: - Config dirs

    @Test func listsTheDefaultConfigDir() async {
        await model.reload()
        #expect(model.accounts.map(\.id) == ["claude"])
        #expect(model.accounts.first?.isRemovable == false)
        #expect(model.accounts.first?.defaultName == "Default")
        #expect(model.automaticStatus == .signedOut)
    }

    @Test func addsOnlyRealConfigDirsOnce() async throws {
        let empty = try home.makeDirectory("empty")
        #expect(await !model.addDirectory(empty))
        #expect(model.directoryMessage?.contains("not a Claude config dir") == true)
        #expect(model.message == nil)

        let work = try home.write("{}", to: "work/settings.json").deletingLastPathComponent()
        #expect(await model.addDirectory(work))
        #expect(model.directoryMessage == nil)
        #expect(settings.settings.claude.extraDirectories == [work.path])
        #expect(await !model.addDirectory(work))
        #expect(model.directoryMessage == "That config dir is already listed.")
    }

    @Test func accountsFollowSettingsAndReadingsAtOnce() async throws {
        try home.write("{}", to: ".claude-work/settings.json")
        await model.reload()
        #expect(model.accounts.map(\.id) == ["claude", "claude-work"])
        model.setEnabled("claude-work", false)
        #expect(model.accounts.last?.isEnabled == false)
        model.setEnabled("claude-work", true)
        #expect(model.accounts.last?.isEnabled == true)

        #expect(model.accounts.last?.reportedPlan == nil)
        let reading = ProviderUsage(
            provider: .claude,
            accounts: [
                AccountUsage(id: "claude-work", name: "work", plan: "Max 5x", observedAt: Date())
            ])
        usage.restore([.claude: reading])
        #expect(model.accounts.last?.reportedPlan == "Max 5x")
    }

    @Test func removeDirectoryClearsNamePlanSwitchAndPin() async throws {
        let work = try home.write("{}", to: "work/settings.json").deletingLastPathComponent()
        #expect(await model.addDirectory(work))
        await model.reload()
        let id = try #require(model.accounts.first { $0.isRemovable }?.id)
        model.rename(id, to: "Day job")
        model.setPlanOverride(id, "Pro")
        model.setEnabled(id, false)
        settings.update {
            $0.menuBar.pinnedAccounts[.claude] = id
            $0.cards.expanded = [.account(.claude, id)]
        }
        model.removeDirectory(id)
        let claude = settings.settings.claude
        #expect(claude.extraDirectories.isEmpty)
        #expect(claude.accountNames.isEmpty)
        #expect(claude.planOverrides.isEmpty)
        #expect(claude.disabledAccounts.isEmpty)
        #expect(settings.settings.menuBar.pinnedAccounts.isEmpty)
        #expect(settings.settings.cards.expanded.isEmpty)
    }

    @Test func theDefaultAccountCannotBeTurnedOffOrRemoved() async {
        model.setEnabled("claude", false)
        model.setEnabled("claude-work", false)
        #expect(settings.settings.claude.disabledAccounts == ["claude-work"])
        await model.reload()
        model.removeDirectory("claude")
        #expect(model.accounts.map(\.id) == ["claude"])
    }

    @Test func renameAndPlanStoreTrimmedText() {
        model.rename("claude", to: "  Home  ")
        #expect(settings.settings.claude.accountNames["claude"] == "Home")
        model.rename("claude", to: "   ")
        #expect(settings.settings.claude.accountNames["claude"] == nil)
        model.setPlanOverride("claude", " Pro ")
        #expect(settings.settings.claude.planOverrides["claude"] == "Pro")
        model.setPlanOverride("claude", nil)
        #expect(settings.settings.claude.planOverrides.isEmpty)
    }

    // MARK: - Connection

    @Test func failedConnectKeepsTheConnectionOff() async {
        #expect(await !model.connectAutomatically())
        #expect(settings.settings.claude.connection == .off)
        #expect(settings.settings.claude.hasConfirmedKeychainAccess)
        #expect(model.message != nil)
        #expect(credentialChanges == 0)
    }

    @Test func successfulConnectSwitchesToAutomatic() async {
        storeClaudeCodeLogin()
        gate.open()
        #expect(await model.connectAutomatically())
        #expect(settings.settings.claude.connection == .automatic)
        #expect(model.message == "Connected.")
        #expect(credentialChanges == 1)
        #expect(!model.isWorking)
    }

    @Test func reconnectingInTheSameModeRefreshesClaude() async {
        storeClaudeCodeLogin()
        gate.open()
        #expect(await model.connectAutomatically())
        #expect(await model.connectAutomatically())
        #expect(credentialChanges == 2)
    }

    @Test func manualReconnectRefreshesClaude() async {
        gate.open()
        #expect(await connectManually("first"))
        #expect(settings.settings.claude.connection == .manual)
        #expect(await connectManually("second"))
        #expect(manualItem?.contains("second") == true)
        #expect(credentialChanges == 2)
    }

    @Test func failedManualReconnectKeepsTheEarlierConnection() async {
        gate.open()
        #expect(await connectManually("first"))
        status.withLock { $0 = 401 }
        #expect(await !connectManually("second"))
        #expect(settings.settings.claude.connection == .manual)
        #expect(manualItem?.contains("first") == true)
        #expect(model.message?.contains("rejected") == true)
        #expect(credentialChanges == 1)
    }

    @Test func turningClaudeOffDiscardsALateConnect() async {
        storeClaudeCodeLogin()
        let connect = Task { await model.connectAutomatically() }
        #expect(await gate.waitForArrivals())
        settings.update { $0.claude.isEnabled = false }
        gate.open()
        #expect(await !connect.value)
        #expect(settings.settings.claude.connection == .off)
        #expect(model.message == "Claude was turned off, so the connection was not saved.")
    }

    @Test func newerAttemptWinsOverOlder() async {
        storeClaudeCodeLogin()
        let connect = Task { await model.connectAutomatically() }
        #expect(await gate.waitForArrivals())
        await model.disconnect()
        gate.open()
        #expect(await !connect.value)
        #expect(settings.settings.claude.connection == .off)
        #expect(!model.isWorking)
    }

    @Test func disconnectManualDeletesTheItem() async {
        gate.open()
        #expect(await connectManually("token"))
        #expect(manualItem != nil)
        await model.disconnect()
        #expect(manualItem == nil)
        #expect(settings.settings.claude.connection == .off)
        #expect(credentialChanges == 2)
    }

    @Test func failedDisconnectKeepsTheConnection() async {
        gate.open()
        #expect(await connectManually("token"))
        keychain.failure = .unavailable
        await model.disconnect()
        #expect(settings.settings.claude.connection == .manual)
        #expect(model.message?.contains("Could not disconnect") == true)
        #expect(credentialChanges == 1)
        #expect(!model.isWorking)
    }
}

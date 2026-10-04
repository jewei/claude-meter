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
    private let settings = SettingsStore(store: MemoryStore())
    private let model: ClaudeSettingsModel

    init() throws {
        home = try TemporaryDirectory()
        try home.write("{}", to: ".claude/settings.json")
        let gate = gate
        let http = FakeHTTPClient { _ in
            await gate.wait()
            return .json(200, #"{"five_hour":{"utilization":10}}"#)
        }
        let settings = settings
        let provider = ClaudeProvider(
            configuration: { @MainActor in settings.claudeConfiguration }, keychain: keychain,
            http: http, store: MemoryStore(), home: home.url)
        model = ClaudeSettingsModel(
            settings: settings, usage: UsageStore(providers: []), provider: provider)
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

    @Test func listsTheDefaultConfigDir() async {
        await model.reload()
        #expect(model.accounts.map(\.id) == ["claude"])
        #expect(model.accounts.first?.isRemovable == false)
        #expect(model.automaticStatus == .signedOut)
    }

    @Test func addsOnlyRealConfigDirsOnce() async throws {
        let empty = try home.makeDirectory("empty")
        #expect(!model.addDirectory(empty))
        #expect(model.message?.contains("not a Claude config dir") == true)

        let work = try home.write("{}", to: "work/settings.json").deletingLastPathComponent()
        #expect(model.addDirectory(work))
        #expect(settings.settings.claude.extraDirectories == [work.path])
        #expect(!model.addDirectory(work))
    }

    @Test func theDefaultAccountCannotBeTurnedOff() {
        model.setEnabled("claude", false)
        model.setEnabled("claude-work", false)
        #expect(settings.settings.claude.disabledAccounts == ["claude-work"])
    }

    @Test func failedConnectKeepsTheConnectionOff() async {
        await model.connectAutomatically()
        #expect(settings.settings.claude.connection == .off)
        #expect(settings.settings.claude.hasConfirmedKeychainAccess)
        #expect(model.message != nil)
    }

    @Test func successfulConnectSwitchesToAutomatic() async {
        storeClaudeCodeLogin()
        gate.open()
        await model.connectAutomatically()
        #expect(settings.settings.claude.connection == .automatic)
    }

    @Test func turningClaudeOffDiscardsALateConnect() async {
        storeClaudeCodeLogin()
        let connect = Task { await model.connectAutomatically() }
        #expect(await gate.waitForArrivals())
        settings.update { $0.claude.isEnabled = false }
        gate.open()
        await connect.value
        #expect(settings.settings.claude.connection == .off)
    }
}

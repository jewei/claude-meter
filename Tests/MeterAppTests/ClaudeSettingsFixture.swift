import Dispatch
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderClaude

@testable import MeterApp

/// A Claude settings model over a fake home, Keychain, and HTTP client. Every usage request
/// waits at ``gate`` until a test opens it, and answers with ``status``.
@MainActor
final class ClaudeSettingsFixture {
    nonisolated static let manualService = AppIdentity.keychainService("claude-oauth")

    let home: TemporaryDirectory
    let keychain = FakeKeychain()
    /// Holds deletes of the manual item while ``DeleteHold/isOn``.
    let deletes = DeleteHold()
    let gate = Gate()
    let status = Locked(200)
    let settings = SettingsStore(store: MemoryStore())
    let usage = UsageStore(providers: [])
    let model: ClaudeSettingsModel
    /// Calls of `onCredentialsChange`, in order with ``events``.
    private(set) var credentialChanges = 0
    /// Settings changes of the connection and credential changes, in order.
    private(set) var events: [String] = []

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
            configuration: { @MainActor in settings.claudeConfiguration },
            keychain: HoldingKeychain(base: keychain, deletes: deletes), http: http,
            store: MemoryStore(), home: home.url)
        model = ClaudeSettingsModel(settings: settings, usage: usage, provider: provider)
        model.onCredentialsChange = { [weak self] in
            self?.credentialChanges += 1
            self?.events.append("credentials")
        }
    }

    deinit {
        home.remove()
    }

    /// Applies Claude settings changes the way `AppModel.settingsDidChange` does: turning
    /// Claude off abandons a running Connect in a new task. Connection changes are recorded in
    /// ``events``, followed by "next turn" when the main actor next runs other work.
    func wireLikeTheApp() {
        settings.onChange = { [weak self] old, new in
            guard let self else { return }
            if old.claude.connection != new.claude.connection {
                events.append("connection \(new.claude.connection)")
                Task { @MainActor in self.events.append("next turn") }
            }
            if old.claude.isEnabled, !new.claude.isEnabled, model.isWorking {
                Task { await self.model.abandonConnect() }
            }
            if !old.claude.isEnabled, new.claude.isEnabled {
                model.claudeWasTurnedOn()
            }
        }
    }

    func storeClaudeCodeLogin() {
        let expiry = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1000)
        keychain.store(
            #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":\#(expiry)}}"#,
            service: "Claude Code-credentials", account: NSUserName(), modifiedAt: Date())
    }

    /// Stores a manual login, as an earlier Connect would.
    func storeManualLogin(_ token: String) {
        keychain.store(
            #"{"accessToken":"\#(token)","connectionID":"connection-\#(token)"}"#,
            service: Self.manualService, account: "manual")
    }

    func connectManually(_ token: String) async -> Bool {
        await model.connectManually(
            accessToken: token, refreshToken: nil, expiresAt: Date().addingTimeInterval(3_600))
    }

    var manualItem: String? {
        keychain.storedPassword(service: Self.manualService, account: "manual")
    }
}

/// Lets a test keep a Disconnect running: while on, a delete of the manual item waits until
/// the test turns it off. The delete runs on the vault's own queue, never on a test thread.
final class DeleteHold: Sendable {
    private let state = Locked((isOn: false, arrivals: 0))
    private let release = DispatchSemaphore(value: 0)

    var isOn: Bool { state.value.isOn }
    /// Deletes that reached the hold.
    var arrivals: Int { state.value.arrivals }

    func turnOn() {
        state.withLock { $0.isOn = true }
    }

    /// Lets every held delete go on.
    func turnOff() {
        state.withLock { $0.isOn = false }
        release.signal()
    }

    fileprivate func waitIfOn() {
        let isOn = state.withLock { state -> Bool in
            if state.isOn { state.arrivals += 1 }
            return state.isOn
        }
        guard isOn else { return }
        release.wait()
        release.signal()
    }
}

/// Passes every call to `base`, and holds deletes of the manual item at `deletes`.
private final class HoldingKeychain: Keychain {
    let base: FakeKeychain
    let deletes: DeleteHold

    init(base: FakeKeychain, deletes: DeleteHold) {
        self.base = base
        self.deletes = deletes
    }

    func password(service: String, account: String?) throws(KeychainError) -> Data? {
        try base.password(service: service, account: account)
    }

    func passwordThroughSecurityTool(
        service: String, account: String
    ) throws(KeychainError) -> Data? {
        try base.passwordThroughSecurityTool(service: service, account: account)
    }

    func items(servicePrefix: String, account: String?) throws(KeychainError) -> [KeychainItem] {
        try base.items(servicePrefix: servicePrefix, account: account)
    }

    func setPassword(_ password: Data, service: String, account: String) throws(KeychainError) {
        try base.setPassword(password, service: service, account: account)
    }

    func deletePassword(service: String, account: String) throws(KeychainError) {
        if service == ClaudeSettingsFixture.manualService { deletes.waitIfOn() }
        try base.deletePassword(service: service, account: account)
    }
}

import Foundation
import MeterDomain
import MeterPlatform
import Observation
import ProviderClaude

/// The Claude section of Settings > Data: the connection and the config dirs.
///
/// Connect and Disconnect are attempts; only the newest attempt applies its result. A Connect
/// is done when its result is stored: a manual Connect stores the tokens in the provider, which
/// asks this model right before and after the Keychain save whether the Connect is still
/// wanted; an automatic Connect stores only the connection setting. Cancel and turning Claude
/// off abandon a running Connect, never a Disconnect.
@MainActor @Observable
public final class ClaudeSettingsModel {
    public struct Account: Identifiable, Equatable, Sendable {
        public let id: AccountID
        /// The provider label as the popover shows it without a display name, such as
        /// `Default` or `Work`.
        public let defaultName: String
        /// The config dir. Nil for Claude Code's active login when no config dir matches it.
        public let path: String?
        public let isDefault: Bool
        public let isEnabled: Bool
        /// The user added this folder, so the user can remove it.
        public let isRemovable: Bool
        /// The plan that the login reports, from the latest reading.
        public let reportedPlan: String?
        public let issue: String?

        /// The default account is always read, and a login without a config dir cannot be
        /// turned off.
        public var canTurnOff: Bool { !isDefault && path != nil }
    }

    static let notSavedMessage = "Claude was turned off, so the connection was not saved."
    static let deleteFailedMessage =
        "Disconnected, but the saved Claude tokens could not be deleted. Claude Meter will try "
        + "again."

    public private(set) var automaticStatus: SignInStatus?
    public private(set) var manualStatus: SignInStatus?
    /// A connect or disconnect is running, and the user did not abandon it.
    public private(set) var isWorking = false
    /// The result of the last connect or disconnect, for the user.
    public private(set) var message: String? {
        didSet { messageIsProblem = false }
    }
    /// ``message`` reports a failure, so Settings shows it as an error.
    public private(set) var messageIsProblem = false
    /// Why the last config dir could not be added, for the user.
    public internal(set) var directoryMessage: String?

    /// Config dirs from the last discovery. Settings and readings apply on each read.
    private(set) var discovered: [ClaudeAccount] = []

    /// Called after every connect or disconnect that changed the stored login, even when the
    /// connection setting kept its value. The composition root refreshes Claude.
    @ObservationIgnored var onCredentialsChange: (() -> Void)?

    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let usage: UsageStore
    @ObservationIgnored let provider: ClaudeProvider
    /// Each connect or disconnect gets a number; only the newest attempt applies its result.
    @ObservationIgnored private var attempt = 0
    /// The attempt that runs now, until it ends. An abandoned Connect stays here until its
    /// provider work ends, so that no leftover cleanup deletes what it may still write back.
    @ObservationIgnored private var running: Attempt?
    /// Each reload gets a number; an older reload never writes over a newer one.
    @ObservationIgnored private var generation = 0

    private struct Attempt {
        enum Kind { case connect, disconnect }

        let number: Int
        let kind: Kind
        var isAbandoned = false
    }

    init(settings: SettingsStore, usage: UsageStore, provider: ClaudeProvider) {
        self.settings = settings
        self.usage = usage
        self.provider = provider
    }

    public var connection: ClaudeSettings.Connection {
        settings.settings.claude.connection
    }

    /// Automatic mode reads another app's Keychain items, so the user confirms it once.
    public var needsKeychainConsent: Bool {
        !settings.settings.claude.hasConfirmedKeychainAccess
    }

    /// Lists the config dirs and checks both logins without reading a secret. A reload that a
    /// newer one overtook stops without writing. When the config dirs cannot be listed in
    /// time, the last list stays.
    ///
    /// A manual login that no connection uses is deleted here, while no attempt runs: the
    /// item of a Disconnect whose delete failed, or one that an automatic Connect could not
    /// delete. This runs at launch and each time Settings reloads.
    public func reload() async {
        generation += 1
        let current = generation
        let found = try? await provider.accounts(for: settings.claudeConfiguration)
        guard current == generation else { return }
        if let found { discovered = found }
        let automatic = await provider.automaticSignInStatus()
        guard current == generation else { return }
        automaticStatus = automatic
        var manual = await provider.manualSignInStatus()
        guard current == generation else { return }
        if manual == .signedIn, connection != .manual, running == nil,
            (try? await provider.disconnectManual()) != nil
        {
            manual = await provider.manualSignInStatus()
            guard current == generation else { return }
        }
        manualStatus = manual
    }

    /// Verifies Claude Code's login with one request, then switches to automatic mode.
    /// Call after the user confirmed Keychain access. Returns true when the connection was
    /// saved.
    @discardableResult
    public func connectAutomatically() async -> Bool {
        settings.update { $0.claude.hasConfirmedKeychainAccess = true }
        return await connect(to: .automatic) { [provider] _ in
            try await provider.verifyAutomaticConnection()
        }
    }

    /// Verifies and stores pasted tokens, then switches to manual mode. A failure keeps any
    /// earlier connection. Returns true when the connection was saved.
    @discardableResult
    public func connectManually(accessToken: String, refreshToken: String?, expiresAt: Date?)
        async -> Bool
    {
        await connect(to: .manual) { [provider] isWanted in
            try await provider.connectManually(
                accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt,
                isWanted: isWanted)
        }
    }

    /// Turns the connection off and deletes the app's own Keychain item in every mode, so no
    /// manual login is left behind. When the delete fails, the connection is off anyway: the
    /// provider forgets the tokens at once, and ``reload()`` tries the delete again.
    public func disconnect() async {
        let wasManual = connection == .manual
        let current = await startAttempt(.disconnect)
        defer { finish(current) }
        var deleteFailed = false
        do {
            try await provider.disconnectManual()
        } catch {
            deleteFailed = true
        }
        // A newer attempt decides the connection.
        guard current == attempt else { return }
        settings.update { $0.claude.connection = .off }
        if deleteFailed, wasManual { report(Self.deleteFailedMessage, isProblem: true) }
        onCredentialsChange?()
        finish(current)
        await reload()
    }

    /// Abandons the Connect that is still running, for example when the user selects Cancel
    /// or turns Claude off: nothing that it verified is stored afterwards. A Disconnect is
    /// never abandoned. Without a running Connect, this clears a failure message, so Cancel
    /// dismisses an error about the tokens.
    public func abandonConnect() async {
        guard let running else {
            if messageIsProblem { message = nil }
            return
        }
        guard running.kind == .connect else { return }
        self.running?.isAbandoned = true
        isWorking = false
        message = nil
        await provider.cancelManualConnect()
    }

    /// Starts a new attempt and returns its number. The number moves first, so a Connect that
    /// is still running can no longer store anything, also while the provider hears of it.
    private func startAttempt(_ kind: Attempt.Kind) async -> Int {
        let previous = running
        attempt += 1
        let current = attempt
        running = Attempt(number: current, kind: kind)
        isWorking = true
        message = nil
        if previous?.kind == .connect { await provider.cancelManualConnect() }
        return current
    }

    /// Ends attempt `number`, unless a newer one runs. An attempt ends once its result is
    /// applied, before the reload after it, so a late Cancel cannot erase that result.
    private func finish(_ number: Int) {
        guard running?.number == number else { return }
        running = nil
        isWorking = false
    }

    /// Whether attempt `number` may still store its result: it is the newest, the user did not
    /// abandon it, and Claude is on.
    private func wants(_ number: Int) -> Bool {
        guard let running, running.number == number else { return false }
        return !running.isAbandoned && settings.settings.claude.isEnabled
    }

    private func connect(
        to target: ClaudeSettings.Connection,
        verify: @Sendable (_ isWanted: @escaping @Sendable () async -> Bool) async throws -> Void
    ) async -> Bool {
        let current = await startAttempt(.connect)
        defer { finish(current) }
        let isWanted: @Sendable () async -> Bool = { @MainActor [weak self] in
            self?.wants(current) ?? false
        }
        do {
            try await verify(isWanted)
        } catch is CancellationError {
            return false
        } catch {
            guard current == attempt else { return false }
            if wants(current) {
                report(Self.text(for: error), isProblem: true)
            } else {
                reportNotSaved()
            }
            finish(current)
            await reload()
            return false
        }
        // A newer attempt decides the connection.
        guard current == attempt else { return false }
        if target != .manual {
            // The provider stored nothing, so this is the moment that decides.
            guard wants(current) else {
                reportNotSaved()
                finish(current)
                await reload()
                return false
            }
            // A manual login from an earlier connection must not stay behind. It goes before
            // the settings change, so that one turn changes the setting and asks for one
            // refresh.
            try? await provider.disconnectManual()
            guard current == attempt else { return false }
        }
        // A manual Connect stored its tokens after `isWanted` agreed, so it is done even when
        // the user abandoned it or turned Claude off since.
        settings.update { $0.claude.connection = target }
        report("Connected.", isProblem: false)
        // A reconnect in the same mode keeps the setting, so refresh explicitly.
        onCredentialsChange?()
        finish(current)
        await reload()
        return true
    }

    /// The Connect was abandoned or Claude was turned off; nothing was stored.
    private func reportNotSaved() {
        message = settings.settings.claude.isEnabled ? nil : Self.notSavedMessage
    }

    private func report(_ text: String, isProblem: Bool) {
        message = text
        messageIsProblem = isProblem
    }

    /// Error text for the user, always redacted.
    private static func text(for error: any Error) -> String {
        ProviderError(wrapping: error).issue.message
    }
}

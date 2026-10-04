import Foundation
import MeterDomain
import MeterPlatform
import Observation
import ProviderClaude

/// The Claude section of Settings > Data: the connection and the config dirs.
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

    public private(set) var automaticStatus: SignInStatus?
    public private(set) var manualStatus: SignInStatus?
    /// A connect or disconnect is running.
    public private(set) var isWorking = false
    /// The result of the last connect or disconnect, for the user.
    public private(set) var message: String? {
        didSet { messageIsProblem = false }
    }
    /// ``message`` reports a failure, so Settings shows it as an error.
    public private(set) var messageIsProblem = false
    /// Why the last config dir could not be added, for the user.
    public private(set) var directoryMessage: String?

    /// Config dirs from the last discovery. Settings and readings apply on each read.
    private var discovered: [ClaudeAccount] = []

    /// Called after every connect or disconnect that changed the stored login, even when the
    /// connection setting kept its value. The composition root refreshes Claude.
    @ObservationIgnored var onCredentialsChange: (() -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let usage: UsageStore
    @ObservationIgnored private let provider: ClaudeProvider
    /// Each connect or disconnect gets a number; only the newest attempt applies its result.
    @ObservationIgnored private var attempt = 0
    /// Each reload gets a number; an older reload never writes over a newer one.
    @ObservationIgnored private var generation = 0

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

    /// The config dirs, default first, then any login in the latest reading that matches no
    /// config dir, so the user can name it and set its plan. The switch state, the remove
    /// button, and the reported plan come from the current settings and reading each time, so
    /// they never lag behind.
    public var accounts: [Account] {
        let claude = settings.settings.claude
        let configured = Set(claude.extraDirectories)
        let reported = usage.readings[.claude]?.value
        let directories = discovered.map { account in
            Account(
                id: account.id, defaultName: PresentationContext.friendlyName(account.name),
                path: account.directory.path, isDefault: account.isDefault,
                isEnabled: account.id == ClaudeAccount.defaultID
                    || !claude.disabledAccounts.contains(account.id),
                isRemovable: configured.contains(account.directory.path),
                reportedPlan: reported?.account(account.id)?.plan,
                issue: account.issue?.message)
        }
        let listed = Set(discovered.map(\.id))
        let unmapped = (reported?.accounts ?? []).filter { !listed.contains($0.id) }.map { usage in
            Account(
                id: usage.id, defaultName: PresentationContext.friendlyName(usage.name),
                path: nil, isDefault: usage.id == ClaudeAccount.defaultID, isEnabled: true,
                isRemovable: false, reportedPlan: usage.plan, issue: nil)
        }
        return directories + unmapped
    }

    /// Lists the config dirs and checks both logins without reading a secret. A reload that a
    /// newer one overtook stops without writing.
    public func reload() async {
        generation += 1
        let current = generation
        let found = await provider.accounts(for: settings.claudeConfiguration)
        guard current == generation else { return }
        discovered = found
        let automatic = await provider.automaticSignInStatus()
        guard current == generation else { return }
        automaticStatus = automatic
        let manual = await provider.manualSignInStatus()
        guard current == generation else { return }
        manualStatus = manual
    }

    /// Verifies Claude Code's login with one request, then switches to automatic mode.
    /// Call after the user confirmed Keychain access. Returns true when the connection was
    /// saved.
    @discardableResult
    public func connectAutomatically() async -> Bool {
        settings.update { $0.claude.hasConfirmedKeychainAccess = true }
        return await connect(to: .automatic) { [provider] in
            try await provider.verifyAutomaticConnection()
        }
    }

    /// Verifies and stores pasted tokens, then switches to manual mode. A failure keeps any
    /// earlier connection. Returns true when the connection was saved.
    @discardableResult
    public func connectManually(accessToken: String, refreshToken: String?, expiresAt: Date?)
        async -> Bool
    {
        await connect(to: .manual) { [provider] in
            try await provider.connectManually(
                accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
        }
    }

    /// Turns the connection off and deletes the app's own Keychain item in every mode, so no
    /// manual login is left behind. In manual mode a failed delete keeps the connection.
    public func disconnect() async {
        await startAttempt()
        let current = attempt
        isWorking = true
        defer { if current == attempt { isWorking = false } }
        do {
            try await provider.disconnectManual()
        } catch {
            if connection == .manual {
                if current == attempt { fail(error) }
                return
            }
        }
        // A newer attempt decides the connection.
        guard current == attempt else { return }
        settings.update { $0.claude.connection = .off }
        message = nil
        onCredentialsChange?()
        await reload()
    }

    /// Abandons a connect that is still running, for example when the user selects Cancel or
    /// turns Claude off. Nothing that attempt verified is stored afterwards.
    public func abandonConnect() async {
        attempt += 1
        isWorking = false
        message = nil
        await provider.cancelManualConnect()
    }

    /// Starts a new attempt. A connect that is still running stores nothing afterwards.
    private func startAttempt() async {
        if isWorking { await provider.cancelManualConnect() }
        attempt += 1
    }

    private func connect(
        to connection: ClaudeSettings.Connection, verify: @Sendable () async throws -> Void
    ) async -> Bool {
        await startAttempt()
        let current = attempt
        isWorking = true
        message = nil
        defer { if current == attempt { isWorking = false } }
        var saved = false
        do {
            try await verify()
            // Another attempt started, so this result is stale.
            guard current == attempt else { return false }
            if settings.settings.claude.isEnabled {
                settings.update { $0.claude.connection = connection }
                message = "Connected."
                saved = true
                if connection == .automatic {
                    // A manual login from an earlier connection must not stay behind.
                    try? await provider.disconnectManual()
                }
                // A reconnect in the same mode keeps the setting, so refresh explicitly.
                onCredentialsChange?()
            } else {
                message = "Claude was turned off, so the connection was not saved."
            }
        } catch is CancellationError {
            return false
        } catch {
            guard current == attempt else { return false }
            fail(error)
        }
        await reload()
        return saved
    }

    /// Shows a failure as an error message.
    private func fail(_ error: any Error) {
        message = Self.text(for: error)
        messageIsProblem = true
    }

    /// Error text for the user, always redacted.
    private static func text(for error: any Error) -> String {
        ProviderError(wrapping: error).issue.message
    }

    // MARK: - Config dirs

    /// Adds a folder that holds `settings.json` or `projects`. Returns false and sets
    /// ``directoryMessage`` when the folder is not a Claude config dir (or does not answer
    /// within 5 s), or is already listed, including the default dir before the first reload.
    @discardableResult
    public func addDirectory(_ url: URL) async -> Bool {
        guard let canonical = await ClaudeProvider.configDirectory(at: url) else {
            directoryMessage = "Choose a folder that holds settings.json or projects."
            return false
        }
        // A fresh discovery, so the default dir counts even before the first reload.
        let found = await provider.accounts(for: settings.claudeConfiguration)
        let listed = found.map(\.canonicalPath) + settings.settings.claude.extraDirectories
        guard !listed.contains(canonical.path) else {
            directoryMessage = "That config dir is already listed."
            return false
        }
        directoryMessage = nil
        settings.update { $0.claude.extraDirectories.append(canonical.path) }
        return true
    }

    /// Removes a folder that the user added, with its name, plan badge, switch, and pin.
    public func removeDirectory(_ id: AccountID) {
        guard let account = accounts.first(where: { $0.id == id }), account.isRemovable else {
            return
        }
        settings.update { settings in
            settings.claude.extraDirectories.removeAll { $0 == account.path }
            settings.forgetAccount(id, of: .claude)
        }
    }

    /// The default account can never be turned off.
    public func setEnabled(_ id: AccountID, _ isEnabled: Bool) {
        guard id != ClaudeAccount.defaultID else { return }
        settings.update { settings in
            if isEnabled {
                settings.claude.disabledAccounts.remove(id)
            } else {
                settings.claude.disabledAccounts.insert(id)
            }
        }
    }

    /// Stores the trimmed name. A blank name removes it.
    public func rename(_ id: AccountID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.claude.accountNames[id] = trimmed.isEmpty ? nil : trimmed }
    }

    /// A badge for a login that reports no plan. Nil or a blank plan removes it.
    public func setPlanOverride(_ id: AccountID, _ plan: String?) {
        let trimmed = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.claude.planOverrides[id] = trimmed?.isEmpty == false ? trimmed : nil }
    }
}

extension SettingsStore {
    var claudeConfiguration: ClaudeConfiguration {
        let claude = settings.claude
        let connection: ClaudeConfiguration.Connection =
            switch claude.isEnabled ? claude.connection : .off {
            case .off: .off
            case .automatic: .automatic
            case .manual: .manual
            }
        return ClaudeConfiguration(
            connection: connection,
            extraDirectories: claude.extraDirectories.map { URL(fileURLWithPath: $0) },
            disabledAccounts: claude.disabledAccounts)
    }
}

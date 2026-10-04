import Foundation
import MeterDomain
import Observation
import ProviderClaude

/// The Claude section of Settings > Data: the connection and the config dirs.
@MainActor @Observable
public final class ClaudeSettingsModel {
    public struct Account: Identifiable, Equatable, Sendable {
        public let id: AccountID
        /// The provider label, such as `default` or `work`.
        public let defaultName: String
        public let path: String
        public let isDefault: Bool
        public let isEnabled: Bool
        /// The user added this folder, so the user can remove it.
        public let isRemovable: Bool
        /// The plan that the login reports, from the latest reading.
        public let reportedPlan: String?
        public let issue: String?
    }

    public private(set) var accounts: [Account] = []
    public private(set) var automaticStatus: SignInStatus?
    public private(set) var manualStatus: SignInStatus?
    /// A connect or disconnect is running.
    public private(set) var isWorking = false
    /// The result of the last connect or disconnect, for the user.
    public private(set) var message: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let usage: UsageStore
    @ObservationIgnored private let provider: ClaudeProvider
    /// Each connect gets a number; a result counts only if no newer attempt started.
    @ObservationIgnored private var attempt = 0

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

    /// Lists the config dirs and checks both logins without reading a secret.
    public func reload() async {
        let configured = Set(settings.settings.claude.extraDirectories)
        let plans = Dictionary(
            (usage.readings[.claude]?.value?.accounts ?? []).map { ($0.id, $0.plan) },
            uniquingKeysWith: { first, _ in first })
        accounts = await provider.accounts(for: settings.claudeConfiguration).map { account in
            Account(
                id: account.id, defaultName: account.name, path: account.directory.path,
                isDefault: account.isDefault, isEnabled: account.isEnabled,
                isRemovable: configured.contains(account.directory.path),
                reportedPlan: plans[account.id] ?? nil, issue: account.issue?.message)
        }
        automaticStatus = await provider.automaticSignInStatus()
        manualStatus = await provider.manualSignInStatus()
    }

    /// Verifies Claude Code's login with one request, then switches to automatic mode.
    /// Call after the user confirmed Keychain access.
    public func connectAutomatically() async {
        settings.update { $0.claude.hasConfirmedKeychainAccess = true }
        await connect(to: .automatic) { [provider] in try await provider.verifyAutomaticConnection()
        }
    }

    /// Verifies and stores pasted tokens, then switches to manual mode. A failure keeps any
    /// earlier connection.
    public func connectManually(accessToken: String, refreshToken: String?, expiresAt: Date?) async
    {
        await connect(to: .manual) { [provider] in
            try await provider.connectManually(
                accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
        }
    }

    /// Turns the connection off. Manual mode also deletes the app's own Keychain item.
    public func disconnect() async {
        attempt += 1
        isWorking = true
        defer { isWorking = false }
        if connection == .manual {
            do {
                try await provider.disconnectManual()
            } catch {
                message = error.localizedDescription
                return
            }
        }
        settings.update { $0.claude.connection = .off }
        message = nil
        await reload()
    }

    private func connect(
        to connection: ClaudeSettings.Connection, verify: @Sendable () async throws -> Void
    ) async {
        attempt += 1
        let current = attempt
        isWorking = true
        message = nil
        defer { if current == attempt { isWorking = false } }
        do {
            try await verify()
            // Turning Claude off or starting another attempt makes this result stale.
            guard current == attempt, settings.settings.claude.isEnabled else { return }
            settings.update { $0.claude.connection = connection }
            message = "Connected."
        } catch is CancellationError {
            return
        } catch {
            guard current == attempt else { return }
            message = error.localizedDescription
        }
        await reload()
    }

    // MARK: - Config dirs

    /// Adds a folder that holds `settings.json` or `projects`. Returns false with a message
    /// when the folder is not a Claude config dir or is already listed.
    @discardableResult
    public func addDirectory(_ url: URL) -> Bool {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard ClaudeProvider.isConfigDirectory(canonical) else {
            message = "That folder is not a Claude config dir. Choose one with settings.json."
            return false
        }
        let listed = accounts.map(\.path) + settings.settings.claude.extraDirectories
        guard !listed.contains(canonical.path) else {
            message = "That config dir is already listed."
            return false
        }
        message = nil
        settings.update { $0.claude.extraDirectories.append(canonical.path) }
        Task { await reload() }
        return true
    }

    public func removeDirectory(_ id: AccountID) {
        guard let account = accounts.first(where: { $0.id == id }), account.isRemovable else {
            return
        }
        settings.update { settings in
            settings.claude.extraDirectories.removeAll { $0 == account.path }
            settings.claude.accountNames[id] = nil
            settings.claude.planOverrides[id] = nil
            settings.claude.disabledAccounts.remove(id)
        }
        Task { await reload() }
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
        Task { await reload() }
    }

    public func rename(_ id: AccountID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.claude.accountNames[id] = trimmed.isEmpty ? nil : name }
    }

    /// A badge for a login that reports no plan. Nil removes it.
    public func setPlanOverride(_ id: AccountID, _ plan: String?) {
        settings.update { $0.claude.planOverrides[id] = plan }
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

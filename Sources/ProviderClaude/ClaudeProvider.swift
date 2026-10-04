import Foundation
import MeterDomain
import MeterPlatform

/// Claude quota: one account per Claude Code config dir, or one manual login.
///
/// The provider keeps no usage of its own. Each refresh receives the reading that the app holds
/// and returns every configured account. See `docs/providers/claude-oauth.md` for the external
/// contracts and rules.
public final class ClaudeProvider: UsageProvider, DiagnosticsReporting {
    /// Always ``ProviderID/claude``.
    public var id: ProviderID { .claude }

    let configuration: @Sendable () async -> ClaudeConfiguration
    let home: URL
    let now: @Sendable () -> Date
    let limits: ClaudeLimits
    let gate: RateLimitGate
    let keychain: ClaudeCodeKeychain
    let vault: ManualCredentialVault
    let manualLogin: ManualLogin
    let api: UsageAPI
    let automatic: AutomaticRefresh
    let manual: ManualRefresh
    let lastRefresh = RefreshRecord()

    /// - Parameters:
    ///   - configuration: The user's Claude settings, read at the start of each operation.
    ///   - keychain: Reads Claude Code's items and owns the manual item.
    ///   - http: Sends usage and token requests.
    ///   - store: Keeps the HTTP 429 deadline across relaunch.
    ///   - home: The folder that holds `~/.claude*` config dirs.
    ///   - now: The clock.
    public convenience init(
        configuration: @escaping @Sendable () async -> ClaudeConfiguration,
        keychain: any Keychain = SystemKeychain(),
        http: any HTTPClient = URLSessionHTTPClient.shared,
        store: any KeyValueStore,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            configuration: configuration, keychain: keychain, http: http, store: store, home: home,
            now: now, keychainUser: ClaudeCodeKeychain.currentUser, limits: ClaudeLimits())
    }

    init(
        configuration: @escaping @Sendable () async -> ClaudeConfiguration,
        keychain: any Keychain,
        http: any HTTPClient,
        store: any KeyValueStore,
        home: URL,
        now: @escaping @Sendable () -> Date,
        keychainUser: String,
        limits: ClaudeLimits
    ) {
        self.configuration = configuration
        self.home = home
        self.now = now
        self.limits = limits
        gate = RateLimitGate(store: store, now: now())
        self.keychain = ClaudeCodeKeychain(
            keychain: keychain, user: keychainUser, timeout: limits.localRead)
        vault = ManualCredentialVault(keychain: keychain, timeout: limits.localRead)
        manualLogin = ManualLogin(
            vault: vault, refresher: TokenRefresher(http: http, now: now), now: now)
        api = UsageAPI(http: http, gate: gate, now: now)
        automatic = AutomaticRefresh(
            home: home, keychain: self.keychain,
            logins: LoginReader(keychain: self.keychain, fileTimeout: limits.localRead), api: api,
            now: now, limits: limits)
        manual = ManualRefresh(login: manualLogin, api: api, now: now)
    }

    /// Drops accounts that left the configuration and observations whose login changed.
    /// Uses local reads only.
    public func reconcile(_ previous: ProviderUsage?) async -> ProviderUsage? {
        guard let previous else { return nil }
        let configuration = await configuration()
        switch configuration.connection {
        case .off: return nil
        case .automatic: return await automatic.reconcile(configuration, previous: previous)
        case .manual: return await manual.reconcile(previous: previous)
        }
    }

    /// Reads every configured account. Throws ``ProviderError`` when Claude is not connected,
    /// while the HTTP 429 gate is closed, or when the whole refresh fails.
    public func fetch(previous: ProviderUsage?) async throws -> ProviderUsage {
        let configuration = await configuration()
        let automatic = automatic
        let manual = manual
        do {
            switch configuration.connection {
            case .off:
                throw ProviderError(
                    AccountFailure.notConnectedMessage, needsAction: true, keepsLastReading: false)
            case .automatic:
                // Each account has its own deadline inside the refresh budget; this is only a
                // safety net.
                let result = try await withDeadline(limits.safetyNet) {
                    try await automatic.fetch(configuration, previous: previous)
                }
                lastRefresh.record(result.usage, activeID: result.activeID, at: now())
                return result.usage
            case .manual:
                let usage = try await withDeadline(limits.refresh) {
                    try await manual.fetch(previous: previous)
                }
                lastRefresh.record(usage, activeID: ManualRefresh.accountID, at: now())
                return usage
            }
        } catch let error as TimeoutError {
            let failure = ProviderError(
                "Could not refresh Claude usage. \(error.localizedDescription)")
            lastRefresh.record(failure: failure, at: now())
            throw failure
        } catch let failure as ProviderError {
            lastRefresh.record(failure: failure, at: now())
            throw failure
        }
    }

    /// Sources, the 429 gate, and the outcome of the last refresh. Values are redacted.
    public func diagnostics() async -> [DiagnosticFact] {
        let configuration = await configuration()
        let accounts = await accounts(for: configuration)
        var facts = [
            DiagnosticFact("Connection", configuration.connection.rawValue),
            DiagnosticFact(
                "Config dirs",
                "\(accounts.count) found, \(accounts.filter { !$0.isEnabled }.count) disabled"),
        ]
        for account in accounts {
            if let issue = account.issue {
                facts.append(DiagnosticFact("Config dir \(account.id)", issue.message))
            }
        }
        facts.append(DiagnosticFact("Claude Code login", Self.text(await automaticSignInStatus())))
        facts.append(DiagnosticFact("Manual login", Self.text(await manualSignInStatus())))
        facts.append(
            DiagnosticFact(
                "Rate limited until",
                gate.blockedUntil(now: now()).map { $0.formatted(.iso8601) } ?? "Not limited"))
        return facts + lastRefresh.facts()
    }

    private static func text(_ status: SignInStatus) -> String {
        switch status {
        case .signedIn: "Signed in"
        case .signedOut: "Signed out"
        case .unknown(let reason): "Unknown: \(reason)"
        }
    }
}

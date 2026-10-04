import Foundation
import MeterDomain
import MeterPlatform

/// Reads Codex subscription quota for every configured Codex home.
///
/// A refresh reads each home's `auth.json` once and sends one `GET wham/usage`. When that
/// request cannot work (no usable tokens, an access token that expires within a minute, or
/// HTTP 401 or 403), a short-lived `codex app-server` lets Codex renew its own sign-in. The app
/// never writes, renews, or deletes Codex credentials.
public final class CodexProvider: UsageProvider, DiagnosticsReporting {
    private static let log = Log(.codex)

    private let configuration: @Sendable () async -> CodexConfiguration
    private let environment: [String: String]
    private let userHome: URL
    private let installFolders: [URL]
    private let limits: CodexLimits
    private let refresh: CodexAccountRefresh
    private let now: @Sendable () -> Date
    private let lastAttempts = Locked<[CodexAttempt]>([])

    /// Creates the provider.
    ///
    /// - Parameters:
    ///   - configuration: Reads the current Codex settings. Called at the start of each refresh.
    ///   - http: The client for the usage requests.
    ///   - environment: The app's environment. `CODEX_HOME`, `CODEX_CLI_PATH`, and `PATH` are read.
    ///   - home: The user's home folder, for `~/.codex` and common install folders.
    ///   - recovery: Nil runs the live `codex app-server`. Tests inject a fake.
    ///   - now: The clock for observation times and token expiry.
    public convenience init(
        configuration: @escaping @Sendable () async -> CodexConfiguration,
        http: any HTTPClient = URLSessionHTTPClient.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        recovery: (any CodexRecovery)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            configuration: configuration, http: http, environment: environment, home: home,
            recovery: recovery, now: now, limits: .standard)
    }

    init(
        configuration: @escaping @Sendable () async -> CodexConfiguration,
        http: any HTTPClient,
        environment: [String: String],
        home: URL,
        recovery: (any CodexRecovery)?,
        now: @escaping @Sendable () -> Date,
        limits: CodexLimits,
        installFolders: [URL]? = nil
    ) {
        let installFolders = installFolders ?? CodexExecutable.installFolders(userHome: home)
        self.configuration = configuration
        self.environment = environment
        self.userHome = home
        self.installFolders = installFolders
        self.limits = limits
        self.now = now
        self.refresh = CodexAccountRefresh(
            api: CodexUsageAPI(http: http, resetDetailsLimit: limits.resetDetails),
            recovery: recovery
                ?? CodexAppServer(installFolders: installFolders, stepLimit: limits.appServerStep),
            environment: environment,
            fileReadLimit: limits.fileRead,
            now: now)
    }

    public var id: ProviderID { .codex }

    /// The implicit home first, then the extra homes, each canonical and listed once.
    /// Runs off-main. Empty when the file system does not answer within 5 seconds.
    public func homes(for configuration: CodexConfiguration) async -> [CodexHome] {
        (try? await resolve(configuration)) ?? []
    }

    /// Whether `url` holds `auth.json` or `config.toml`, so it can be a Codex home.
    public static func looksLikeHome(_ url: URL) -> Bool {
        LocalFile.isRegularFile(url.appending(path: "auth.json"))
            || LocalFile.isRegularFile(url.appending(path: "config.toml"))
    }

    /// Checks `home`'s auth file without a network request.
    ///
    /// ChatGPT tokens are signed in. API-key auth is signed out because it has no
    /// subscription quota, and so is a home folder that does not exist. Without usable tokens,
    /// an installed Codex CLI can still find a login during refresh, for example in the
    /// keyring, so the status is unknown.
    public func signInStatus(for home: CodexHome) async -> SignInStatus {
        guard let login = try? await CodexLogin.read(home, timeout: limits.fileRead) else {
            return .unknown("The sign-in check stopped. Open Settings again.")
        }
        switch login {
        case .chatGPT:
            return .signedIn
        case .apiKey, .noHome:
            return .signedOut
        case .missing, .noTokens, .invalid, .unreadable:
            if (try? await locateCLI()) != nil {
                return .unknown("Codex detected; checking sign-in during refresh.")
            }
            if login == .unreadable {
                return .unknown(CodexError.authFileUnreadable.localizedDescription)
            }
            return .signedOut
        }
    }

    /// Drops accounts whose home left the configuration, and observations whose owner is no
    /// longer signed in. A temporary read failure keeps the observation.
    public func reconcile(_ previous: ProviderUsage?) async -> ProviderUsage? {
        guard let previous else { return nil }
        let homes: [CodexHome]
        do {
            homes = try await withDeadline(limits.homeResolution) { try await self.currentHomes() }
        } catch {
            return previous
        }
        let observed = homes.filter { previous.account($0.id)?.hasObservation == true }
        let statuses = await ownerStatuses(of: observed)
        let accounts = homes.compactMap { home -> AccountUsage? in
            guard let account = previous.account(home.id),
                account.belongs(to: statuses[home.id] ?? .unknown)
            else { return nil }
            return account
        }
        return accounts.isEmpty ? nil : ProviderUsage(provider: .codex, accounts: accounts)
    }

    /// Refreshes every configured home, at most three at once, within one 60-second deadline
    /// that includes home resolution. A home that fails keeps its previous observation as stale
    /// while that observation still belongs to the login, and is unavailable otherwise.
    public func fetch(previous: ProviderUsage?) async throws -> ProviderUsage {
        let deadline = ContinuousClock.now + limits.fetch
        let homes: [CodexHome]
        do {
            homes = try await withDeadline(limits.fetch) { try await self.currentHomes() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.error("Codex homes could not be resolved", error)
            throw ProviderError("Could not read the Codex home folders in time. Refresh again.")
        }
        let attempts = await refreshAll(homes, until: deadline)
        try Task.checkCancellation()
        lastAttempts.withLock { $0 = attempts }
        let accounts = attempts.map { attempt in
            let earlier = previous?.account(attempt.home.id)
            let account = attempt.account(previous: earlier)
            if let issue = account.issue, issue.message != earlier?.issue?.message {
                Self.log.warning("\(attempt.home.label): \(issue.message)")
            }
            return account
        }
        return ProviderUsage(provider: .codex, accounts: CodexAttempt.markingSharedLogins(accounts))
    }

    /// The Codex CLI location and, for each home, what the last fetch did.
    public func diagnostics() async -> [DiagnosticFact] {
        let cli = try? await locateCLI()
        var facts = [DiagnosticFact("Codex CLI", cli?.path ?? "Not found")]
        let attempts = lastAttempts.value
        if attempts.isEmpty {
            facts.append(DiagnosticFact("Codex refresh", "None this launch"))
        }
        for attempt in attempts {
            facts += attempt.facts
        }
        return facts
    }

    // MARK: - Work

    /// Runs at most ``CodexLimits/concurrentHomes`` homes at once. A free slot starts the next
    /// home. Results keep the configured order.
    private func refreshAll(
        _ homes: [CodexHome], until deadline: ContinuousClock.Instant
    ) async -> [CodexAttempt] {
        let refresh = self.refresh
        let now = self.now
        let limit = limits.fetch
        let attempt: @Sendable (CodexHome) async -> CodexAttempt = { home in
            let remaining = deadline - .now
            var outcome = CodexAccountRefresh.Outcome.timedOut(after: limit)
            if remaining > .zero,
                let finished = try? await withDeadline(remaining, { try await refresh.run(home) })
            {
                outcome = finished
            }
            return CodexAttempt(home: home, outcome: outcome, attemptedAt: now())
        }
        return await withTaskGroup(of: (Int, CodexAttempt).self) { group in
            var attempts = [CodexAttempt?](repeating: nil, count: homes.count)
            var started = 0
            while started < min(limits.concurrentHomes, homes.count) {
                let index = started
                group.addTask { (index, await attempt(homes[index])) }
                started += 1
            }
            for await (index, finished) in group {
                attempts[index] = finished
                if started < homes.count {
                    let next = started
                    group.addTask { (next, await attempt(homes[next])) }
                    started += 1
                }
            }
            return attempts.compactMap { $0 }
        }
    }

    private func currentHomes() async throws -> [CodexHome] {
        try await resolve(await configuration())
    }

    private func resolve(_ configuration: CodexConfiguration) async throws -> [CodexHome] {
        let environment = self.environment
        let userHome = self.userHome
        return try await BlockingIO.run(timeout: limits.homeResolution) { _ in
            CodexHome.resolve(
                extraHomes: configuration.extraHomes, environment: environment,
                userHome: userHome)
        }
    }

    private func ownerStatuses(of homes: [CodexHome]) async -> [AccountID: OwnerStatus] {
        let limit = limits.fileRead
        return await withTaskGroup(of: (AccountID, OwnerStatus).self) { group in
            for home in homes {
                group.addTask {
                    let login = try? await CodexLogin.read(home, timeout: limit)
                    return (home.id, login?.ownerStatus ?? .unknown)
                }
            }
            var statuses: [AccountID: OwnerStatus] = [:]
            for await (id, status) in group {
                statuses[id] = status
            }
            return statuses
        }
    }

    private func locateCLI() async throws -> URL {
        try await CodexExecutable.locate(
            environment: environment, installFolders: installFolders, timeout: limits.appServerStep
        ).url
    }
}

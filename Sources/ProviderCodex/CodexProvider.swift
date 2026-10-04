import Foundation
import MeterDomain
import MeterPlatform

/// Reads Codex subscription quota for every configured Codex home.
///
/// For each home, `reconcile` reads `auth.json` once when the home has an observation. The
/// fetch reads it once for the credentials and the owner, sends one `GET wham/usage`, and
/// reads the owner once more. When that request cannot work (no usable tokens, an access token
/// that expires within a minute, or HTTP 401 or 403), a short-lived `codex app-server` lets
/// Codex renew or find its own sign-in. The app never writes, renews, or deletes Codex
/// credentials.
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
    ///   - now: The clock for observation times and token expiry.
    public convenience init(
        configuration: @escaping @Sendable () async -> CodexConfiguration,
        http: any HTTPClient = URLSessionHTTPClient.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            configuration: configuration, http: http, environment: environment, home: home,
            recovery: nil, now: now, limits: .standard)
    }

    /// The full initializer. `recovery` nil runs the live `codex app-server`; tests inject a
    /// fake. `installFolders` nil uses ``CodexExecutable/installFolders(userHome:)``.
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
            api: CodexUsageAPI(
                http: http, usageLimit: limits.usageRequest, resetDetailsLimit: limits.resetDetails),
            recovery: recovery
                ?? CodexAppServer(
                    installFolders: installFolders, stepLimit: limits.appServerStep,
                    networkStepLimit: limits.appServerNetworkStep),
            environment: environment,
            fileReadLimit: limits.fileRead,
            now: now)
    }

    /// Always ``ProviderID/codex``.
    public var id: ProviderID { .codex }

    /// The implicit home first, then the extra homes, each canonical and listed once.
    /// Runs off-main.
    ///
    /// - Throws: `CancellationError`, or a ``ProviderError`` that keeps the last reading when
    ///   the file system does not answer within 5 seconds. History roots must use this, so a
    ///   slow disk never looks like "no homes" and never discards the scan state.
    public func resolveHomes(for configuration: CodexConfiguration) async throws -> [CodexHome] {
        do {
            return try await resolve(configuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.homesUnresolved
        }
    }

    /// Like ``resolveHomes(for:)``, for display only: empty when the homes cannot be resolved.
    public func homes(for configuration: CodexConfiguration) async -> [CodexHome] {
        (try? await resolveHomes(for: configuration)) ?? []
    }

    private static let homesUnresolved = ProviderError(
        "Could not read the Codex home folders in time. Refresh again.")

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
    /// keyring, so the status is unknown. A file that cannot be read now is unknown, with what
    /// to do: a refresh does not check it with the CLI either.
    public func signInStatus(for home: CodexHome) async -> SignInStatus {
        guard let login = try? await CodexLogin.read(home, timeout: limits.fileRead) else {
            return .unknown("The sign-in check stopped. Open Settings again.")
        }
        switch login.route {
        case .request:
            return .signedIn
        case .stop(_, status: .signedOut):
            return .signedOut
        case .stop(let error, _):
            return .unknown(error.localizedDescription)
        case .recover:
            if (try? await locateCLI()) != nil {
                return .unknown("Codex detected; checking sign-in during refresh.")
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
    /// that includes home resolution (``CodexLimits/worstCaseFetch`` fits it). A home that
    /// fails keeps its previous observation as stale while that observation still belongs to
    /// the login, and is unavailable otherwise.
    public func fetch(previous: ProviderUsage?) async throws -> ProviderUsage {
        let deadline = ContinuousClock.now + limits.fetch
        let homes: [CodexHome]
        do {
            homes = try await withDeadline(limits.fetch) { try await self.currentHomes() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.error("Codex homes could not be resolved", error)
            throw Self.homesUnresolved
        }
        let holds = Self.rateLimitHolds(in: previous, now: now())
        let attempts = await refreshAll(homes, holds: holds, until: deadline)
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

    /// The rate-limit holds that run at `now`, of every account. A login that got HTTP 429 in
    /// one home is held in every home, because the limit belongs to the login.
    static func rateLimitHolds(in previous: ProviderUsage?, now: Date) -> [RateLimitHold] {
        (previous?.accounts ?? []).compactMap { account in
            guard let owner = account.owner,
                let retryAt = account.rateLimitHold(for: owner, now: now)?.retryAt
            else { return nil }
            return RateLimitHold(owner: owner, retryAt: retryAt)
        }
    }

    /// Runs at most ``CodexLimits/concurrentHomes`` homes at once. A free slot starts the next
    /// home while time is left; after the deadline or a cancel, the homes that did not start
    /// time out without a task. Results keep the configured order.
    private func refreshAll(
        _ homes: [CodexHome], holds: [RateLimitHold], until deadline: ContinuousClock.Instant
    ) async -> [CodexAttempt] {
        let refresh = self.refresh
        let now = self.now
        let attempt: @Sendable (CodexHome) async -> CodexAttempt = { home in
            let remaining = deadline - .now
            var outcome = CodexAccountRefresh.Outcome.timedOut
            if remaining > .zero,
                let finished = try? await withDeadline(
                    remaining, { try await refresh.run(home, holds: holds) })
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
                guard started < homes.count else { continue }
                if ContinuousClock.now >= deadline || Task.isCancelled {
                    for next in started..<homes.count {
                        attempts[next] = CodexAttempt(
                            home: homes[next], outcome: .timedOut, attemptedAt: now())
                    }
                    started = homes.count
                } else {
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

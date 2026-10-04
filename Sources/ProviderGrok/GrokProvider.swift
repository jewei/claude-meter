import Foundation
import MeterDomain
import MeterPlatform

/// Grok Build credit usage for the login of the Grok Build CLI on this Mac.
///
/// Reads the CLI's `auth.json` without changing it and never renews the login: the CLI owns
/// it. A token whose `expires_at` has passed is never sent. The provider reports one account,
/// ``AccountID/default``. Its credits window is binding for the card's severity, but it never
/// selects the menu-bar account, because ``ProviderID/canOwnMenuBar`` is false for Grok.
public final class GrokProvider: UsageProvider, DiagnosticsReporting {
    /// The account label before the user renames it.
    static let accountName = "Grok"
    /// An internal endpoint of the Grok CLI. It can change without notice.
    static let billingURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let requestDeadline: Duration = .seconds(30)
    private static let log = Log(.grok)

    private let authFile: GrokAuthFile
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private let usesCustomHome: Bool
    /// The outcome of the last usage request, for Diagnostics only.
    private let lastRequest = Locked<String?>(nil)

    /// - Parameters:
    ///   - http: Sends the billing request.
    ///   - environment: Supplies `GROK_HOME`.
    ///   - home: The user's home directory, for the default `~/.grok`.
    ///   - now: The clock for expiry checks and observation times.
    public init(
        http: any HTTPClient = URLSessionHTTPClient.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authFile = GrokAuthFile(
            grokHome: Self.homeDirectory(environment: environment, home: home))
        self.http = http
        self.now = now
        self.usesCustomHome = environment["GROK_HOME"].map { !Self.isBlank($0) } ?? false
    }

    /// Always ``ProviderID/grok``.
    public var id: ProviderID { .grok }

    /// The Grok Build CLI's home: `GROK_HOME`, trimmed, when it is set and not blank,
    /// otherwise `~/.grok`. A leading `~` means `home`.
    ///
    /// The CLI resolves a relative `GROK_HOME` against its own working folder, which the app
    /// cannot know; the app's own working folder is `/`. A relative value is taken from `home`,
    /// where a terminal starts. The app sees only the environment that it was started with.
    public static func homeDirectory(environment: [String: String], home: URL) -> URL {
        let value = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return home.appending(path: ".grok", directoryHint: .isDirectory)
        }
        if value == "~" { return home }
        if value.hasPrefix("~/") {
            return home.appending(path: String(value.dropFirst(2)), directoryHint: .isDirectory)
        }
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return home.appending(path: expanded, directoryHint: .isDirectory)
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Removes the previous reading when the CLI's login is gone or belongs to another account.
    /// Reads local files only.
    public func reconcile(_ previous: ProviderUsage?) async -> ProviderUsage? {
        guard let previous else { return nil }
        guard let status = try? await authFile.read(now: now()).ownerStatus else { return previous }
        return previous.accounts.allSatisfy { $0.belongs(to: status) } ? previous : nil
    }

    /// Reads usage for the one Grok account. A failure keeps the previous observation as stale
    /// while it belongs to the signed-in login, and otherwise reports the account as
    /// unavailable. Throws only `CancellationError`.
    public func fetch(previous: ProviderUsage?) async throws -> ProviderUsage {
        let now = now()
        let previous = previous?.account(.default)
        let account: AccountUsage
        switch try await authFile.read(now: now) {
        case .missing:
            account = failed(.signedOut, previous: previous, status: .signedOut, now: now)
        case .unreadable(let failure):
            account = failed(failure, previous: previous, status: .unknown, now: now)
        case .found(let credentials):
            account = try await fetch(credentials, previous: previous, now: now)
        }
        // Log a change of state: a failure that clears, not every success.
        if account.issue == nil, previous?.issue != nil {
            Self.log.notice("Grok refresh recovered.")
        }
        return ProviderUsage(provider: .grok, accounts: [account])
    }

    /// Whether the CLI has a login on this Mac. Reads `auth.json` only and never sends a
    /// request. An expired login still counts as signed in; the card asks the user to renew it.
    public func signInStatus() async -> SignInStatus {
        do {
            switch try await authFile.read(now: now()) {
            case .found: return .signedIn
            case .missing: return .signedOut
            case .unreadable(let failure): return .unknown(failure.issue.message)
            }
        } catch {
            return .unknown("The Grok sign-in check stopped before it finished. Try again.")
        }
    }

    /// Where the login comes from and how the last request ended. Never shows a secret.
    public func diagnostics() async -> [DiagnosticFact] {
        let now = now()
        var facts = [
            DiagnosticFact("GROK_HOME", usesCustomHome ? "Set" : "Not set"),
            DiagnosticFact("Sign-in file", authFile.url.path),
        ]
        guard let lookup = try? await authFile.read(now: now) else { return facts }
        switch lookup {
        case .found(let credentials):
            facts.append(DiagnosticFact("Sign-in entry", credentials.scope))
            let expiry = credentials.expiresAt.map { $0.formatted(.iso8601) } ?? "Unknown"
            facts.append(
                DiagnosticFact(
                    "Token expiry", credentials.isExpired(at: now) ? "Expired at \(expiry)" : expiry
                ))
            facts.append(DiagnosticFact("Account identity", credentials.identitySource.rawValue))
        case .missing:
            facts.append(DiagnosticFact("Sign-in entry", "Missing"))
        case .unreadable(let failure):
            facts.append(DiagnosticFact("Sign-in entry", failure.issue.message))
        }
        facts.append(DiagnosticFact("Last usage request", lastRequest.value ?? "None"))
        return facts
    }

    // MARK: - Fetching

    private func fetch(
        _ credentials: GrokCredentials, previous: AccountUsage?, now: Date
    ) async throws -> AccountUsage {
        let owner = credentials.owner
        // Grok asked this login to pause after HTTP 429. Send nothing before the retry time, so
        // the card's countdown is true. This comes first, so an expired key keeps the hold.
        if let previous, let hold = previous.rateLimitHold(for: owner, now: now) {
            return previous.retained(issue: hold, now: now)
        }
        guard !credentials.isExpired(at: now) else {
            return failed(.sessionExpired, previous: previous, status: .signedIn(owner), now: now)
        }
        let result: Result<AccountUsage, GrokFailure>
        do {
            let report = try await requestBilling(bearer: credentials.bearer, now: now)
            result = .success(report.account(owner: owner, now: now))
        } catch let failure as GrokFailure {
            result = .failure(failure)
        }
        recordRequest(result.map { _ in () }, at: now)
        // The response belongs to the login that sent it. Discard it if the login changed.
        let after = try await authFile.read(now: now).ownerStatus
        switch after {
        case .signedOut:
            return failed(.signedOut, previous: previous, status: after, now: now)
        case .signedIn(let current) where current != owner:
            return failed(.signInChanged, previous: previous, status: after, now: now)
        case .signedIn, .unknown:
            break
        }
        switch result {
        case .success(let account):
            return account
        case .failure(let failure):
            return failed(failure, previous: previous, status: .signedIn(owner), now: now)
        }
    }

    /// Throws ``GrokFailure`` or `CancellationError`.
    private func requestBilling(bearer: String, now: Date) async throws -> GrokBillingReport {
        let request = HTTPRequest(
            .get, url: Self.billingURL,
            headers: [
                "Authorization": "Bearer \(bearer)",
                "Accept": "application/json",
                "User-Agent": "ClaudeMeter",
            ],
            retry: .transientFailures, deadline: Self.requestDeadline)
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw GrokFailure(transport: error)
        }
        try Task.checkCancellation()
        guard response.isSuccess else {
            throw GrokFailure(
                status: response.status, retryAfter: response.header("retry-after"), now: now)
        }
        return try GrokBillingReport(body: response.body)
    }

    /// The account after `failure`: the previous observation, kept as stale while it belongs to
    /// `status`, or an unavailable account. A kept observation past its period has an unknown
    /// window and no on-demand spend; the prepaid balance stays
    /// (``AccountUsage/retained(issue:now:)``).
    private func failed(
        _ failure: GrokFailure, previous: AccountUsage?, status: OwnerStatus, now: Date
    ) -> AccountUsage {
        // A refresh that sent nothing for a login that got HTTP 429, such as one that could not
        // read the login, keeps the hold while the login can still be the same. Otherwise the
        // next refresh would send before the retry time.
        if let previous, let hold = previous.rateLimitHold(admittedBy: status, now: now) {
            return previous.retained(issue: hold, now: now)
        }
        // Log a change of state, not the same failure at every refresh.
        if previous?.issue != failure.issue {
            Self.log.warning("Grok refresh failed: \(failure.issue.message)")
        }
        if let previous, previous.hasObservation, previous.belongs(to: status) {
            return previous.retained(issue: failure.issue, now: now)
        }
        var owner: AccountOwner?
        if case .signedIn(let current) = status { owner = current }
        return .unavailable(
            id: .default, name: Self.accountName, issue: failure.issue, attemptedAt: now,
            owner: owner)
    }

    /// Diagnostics show how the last request that was sent ended. A refresh that sent nothing,
    /// such as a signed-out one, leaves it unchanged.
    private func recordRequest(_ outcome: Result<Void, GrokFailure>, at now: Date) {
        let time = now.formatted(.iso8601)
        lastRequest.withLock {
            switch outcome {
            case .success: $0 = "Succeeded at \(time)"
            case .failure(let failure): $0 = "Failed at \(time): \(failure.issue.message)"
            }
        }
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

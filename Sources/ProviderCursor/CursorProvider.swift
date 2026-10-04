import Foundation
import MeterDomain
import MeterPlatform

/// Cursor billing-period usage for the login that the Cursor app stores on this Mac.
///
/// Reads Cursor's credentials without changing them and never renews them: Cursor owns its
/// login. A token whose known expiry has passed is never sent. The provider reports one
/// account, ``AccountID/default``. Its windows only display, because Cursor can never own the
/// menu bar.
public final class CursorProvider: UsageProvider, DiagnosticsReporting {
    /// The account label before the user renames it.
    static let accountName = "Cursor"
    private static let log = Log(.cursor)

    private let store: CursorCredentialStore
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    /// The outcome of the last usage request, for Diagnostics only.
    private let lastRequest = Locked<String?>(nil)

    /// - Parameters:
    ///   - keychain: Read only, for the access token when the state database has none.
    ///   - http: Sends the usage and plan requests.
    ///   - home: The user's home directory, which holds Cursor's state database.
    ///   - now: The clock for expiry checks and observation times.
    public init(
        keychain: any Keychain = SystemKeychain(),
        http: any HTTPClient = URLSessionHTTPClient.shared,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = CursorCredentialStore(home: home, keychain: keychain)
        self.http = http
        self.now = now
    }

    public var id: ProviderID { .cursor }

    /// Removes the previous reading when Cursor's login is gone or belongs to another account.
    /// Reads local credentials only.
    public func reconcile(_ previous: ProviderUsage?) async -> ProviderUsage? {
        guard let previous else { return nil }
        guard let status = try? await store.read().ownerStatus else { return previous }
        return previous.accounts.allSatisfy { $0.belongs(to: status) } ? previous : nil
    }

    /// Reads usage for the one Cursor account. A failure keeps the previous observation as
    /// stale while it belongs to the signed-in login, and otherwise reports the account as
    /// unavailable. Throws only `CancellationError`.
    public func fetch(previous: ProviderUsage?) async throws -> ProviderUsage {
        let now = now()
        let previous = previous?.account(.default)
        let account: AccountUsage
        switch try await store.read() {
        case .missing:
            account = failed(.signedOut, previous: previous, status: .signedOut, now: now)
        case .unreadable(let failure):
            account = failed(failure, previous: previous, status: .unknown, now: now)
        case .found(let credentials):
            account = try await fetch(credentials, previous: previous, now: now)
        }
        return ProviderUsage(provider: .cursor, accounts: [account])
    }

    /// Whether Cursor has a login on this Mac. Reads the state database and the Keychain item
    /// attributes only, and never sends a request.
    public func signInStatus() async -> SignInStatus {
        do {
            return try await store.signInStatus()
        } catch {
            return .unknown("The Cursor sign-in check stopped before it finished. Try again.")
        }
    }

    /// Where the credentials come from and how the last request ended. Never shows a secret.
    public func diagnostics() async -> [DiagnosticFact] {
        guard let inspected = try? await store.inspect() else { return [] }
        var facts = [DiagnosticFact("State database", inspected.database.rawValue)]
        switch inspected.lookup {
        case .found(let credentials):
            facts.append(
                DiagnosticFact("Access token", "Found in the \(credentials.source.rawValue)"))
            facts.append(DiagnosticFact("Token expiry", expiryText(credentials)))
            facts.append(
                DiagnosticFact(
                    "Account identity",
                    credentials.subject == nil ? "Token digest" : "Token subject"))
            facts.append(
                DiagnosticFact(
                    "Refresh token in database", credentials.hasRefreshToken ? "Yes" : "No"))
            facts.append(DiagnosticFact("Local plan", credentials.membership ?? "None"))
        case .missing:
            facts.append(DiagnosticFact("Access token", "Missing"))
        case .unreadable(let failure):
            facts.append(DiagnosticFact("Access token", failure.issue.message))
        }
        facts.append(DiagnosticFact("Last usage request", lastRequest.value ?? "None"))
        return facts
    }

    // MARK: - Fetching

    private func fetch(
        _ credentials: CursorCredentials, previous: AccountUsage?, now: Date
    ) async throws -> AccountUsage {
        let owner = credentials.owner
        guard !credentials.isExpired(at: now) else {
            return failed(.sessionExpired, previous: previous, status: .signedIn(owner), now: now)
        }
        let result: Result<AccountUsage, CursorFailure>
        do {
            result = .success(try await requestUsage(credentials, now: now))
        } catch let failure as CursorFailure {
            result = .failure(failure)
        }
        // The response belongs to the login that sent it. Discard it if the login changed.
        let after = try await store.read().ownerStatus
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
            lastRequest.withLock { $0 = "Succeeded at \(now.formatted(.iso8601))" }
            return account
        case .failure(let failure):
            return failed(failure, previous: previous, status: .signedIn(owner), now: now)
        }
    }

    /// Throws ``CursorFailure`` or `CancellationError`.
    private func requestUsage(_ credentials: CursorCredentials, now: Date) async throws
        -> AccountUsage
    {
        let token = credentials.accessToken
        let request = CursorAPI.connectRequest(
            CursorAPI.usageURL, token: token, deadline: CursorAPI.usageDeadline)
        let body = try await CursorAPI.send(request, http: http, now: now)
        let report = try CursorUsageReport(body: body)
        guard report.isEnabled else { throw CursorFailure.usageDisabled }
        var plan = credentials.membership
        if plan == nil {
            plan = try await planName(token: token, now: now)
        }
        return report.account(plan: plan, owner: credentials.owner, now: now)
    }

    /// The plan from `GetPlanInfo`, used only when Cursor stored no plan. Its failures are
    /// silent, because the plan only labels the card.
    private func planName(token: String, now: Date) async throws -> String? {
        let request = CursorAPI.connectRequest(
            CursorAPI.planURL, token: token, deadline: CursorAPI.planDeadline)
        do {
            return CursorPlan.name(
                planInfo: try await CursorAPI.send(request, http: http, now: now))
        } catch is CursorFailure {
            return nil
        }
    }

    /// The account after `failure`: the previous observation, kept as stale while it belongs to
    /// `status`, or an unavailable account.
    private func failed(
        _ failure: CursorFailure, previous: AccountUsage?, status: OwnerStatus, now: Date
    ) -> AccountUsage {
        lastRequest.withLock {
            $0 = "Failed at \(now.formatted(.iso8601)): \(failure.issue.message)"
        }
        if failure != .offline {
            Self.log.warning("Cursor refresh failed: \(failure.issue.message)")
        }
        if failure.keepsObservation, let previous, previous.hasObservation,
            previous.belongs(to: status)
        {
            return previous.retained(issue: failure.issue, now: now)
        }
        var owner: AccountOwner?
        if case .signedIn(let current) = status { owner = current }
        return .unavailable(
            id: .default, name: Self.accountName, issue: failure.issue, attemptedAt: now,
            owner: owner)
    }

    private func expiryText(_ credentials: CursorCredentials) -> String {
        guard let expiresAt = credentials.expiresAt else { return "Unknown" }
        let text = expiresAt.formatted(.iso8601)
        return credentials.isExpired(at: now()) ? "Expired at \(text)" : text
    }
}

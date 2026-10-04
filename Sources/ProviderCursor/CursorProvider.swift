import Foundation
import MeterDomain
import MeterPlatform

/// Cursor billing-period usage for the login that the Cursor app stores on this Mac.
///
/// Reads Cursor's credentials without changing them and never renews them: Cursor owns its
/// login. A token whose known expiry has passed is never sent. The provider reports one
/// account, ``AccountID/default``. Its billing window is binding for the card's severity, but
/// it never selects the menu-bar account, because ``ProviderID/canOwnMenuBar`` is false for
/// Cursor.
public final class CursorProvider: UsageProvider, DiagnosticsReporting {
    /// The account label before the user renames it.
    static let accountName = "Cursor"
    /// A plan from `GetPlanInfo` is asked for again after this long. Plans rarely change, and
    /// every request counts against Cursor's limits.
    static let planMaxAge: TimeInterval = 24 * 3_600
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

    /// Always ``ProviderID/cursor``.
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
        // Log a change of state: a failure that clears, not every success.
        if account.issue == nil, previous?.issue != nil {
            Self.log.notice("Cursor refresh recovered.")
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
        // Cursor asked this login to pause after HTTP 429. Send nothing before the retry time,
        // so the card's countdown is true.
        if let previous, let hold = previous.rateLimitHold(for: owner, now: now) {
            return previous.retained(issue: hold, now: now)
        }
        let result: Result<AccountUsage, CursorFailure>
        do {
            result = .success(try await requestUsage(credentials, previous: previous, now: now))
        } catch let failure as CursorFailure {
            result = .failure(failure)
        }
        recordRequest(result.map { _ in () }, at: now)
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
            return account
        case .failure(let failure):
            return failed(failure, previous: previous, status: .signedIn(owner), now: now)
        }
    }

    /// Throws ``CursorFailure`` or `CancellationError`.
    private func requestUsage(
        _ credentials: CursorCredentials, previous: AccountUsage?, now: Date
    ) async throws -> AccountUsage {
        let token = credentials.accessToken
        let request = CursorAPI.connectRequest(
            CursorAPI.usageURL, token: token, deadline: CursorAPI.usageDeadline)
        let body = try await CursorAPI.send(request, http: http, now: now)
        let report = try CursorUsageReport(body: body)
        guard report.isEnabled else { throw CursorFailure.usageDisabled }
        var plan = credentials.membership
        if plan == nil {
            let known = previous?.owner == credentials.owner ? previous : nil
            plan = try await planName(token: token, known: known, now: now)
        }
        return report.account(plan: plan, owner: credentials.owner, now: now)
    }

    /// The plan from `GetPlanInfo`, used only when Cursor stored no plan. A plan that the same
    /// login showed less than ``planMaxAge`` ago is reused without a request, and a failed
    /// request keeps it, because the plan only labels the card.
    private func planName(token: String, known: AccountUsage?, now: Date) async throws
        -> String?
    {
        let knownPlan = known?.plan
        if let knownPlan, let observedAt = known?.observedAt, observedAt <= now,
            now.timeIntervalSince(observedAt) < Self.planMaxAge
        {
            return knownPlan
        }
        let request = CursorAPI.connectRequest(
            CursorAPI.planURL, token: token, deadline: CursorAPI.planDeadline)
        do {
            return CursorPlan.name(
                planInfo: try await CursorAPI.send(request, http: http, now: now)) ?? knownPlan
        } catch is CursorFailure {
            return knownPlan
        }
    }

    /// The account after `failure`: the previous observation, kept as stale while it belongs to
    /// `status`, or an unavailable account. A kept observation past its billing period has an
    /// unknown window and no spend (``AccountUsage/retained(issue:now:)``).
    private func failed(
        _ failure: CursorFailure, previous: AccountUsage?, status: OwnerStatus, now: Date
    ) -> AccountUsage {
        // Log a change of state, not the same failure at every refresh.
        if previous?.issue != failure.issue {
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

    /// Diagnostics show how the last request that was sent ended. A refresh that sent nothing,
    /// such as a signed-out one, leaves it unchanged.
    private func recordRequest(_ outcome: Result<Void, CursorFailure>, at now: Date) {
        let time = now.formatted(.iso8601)
        lastRequest.withLock {
            switch outcome {
            case .success: $0 = "Succeeded at \(time)"
            case .failure(let failure): $0 = "Failed at \(time): \(failure.issue.message)"
            }
        }
    }

    private func expiryText(_ credentials: CursorCredentials) -> String {
        guard let expiresAt = credentials.expiresAt else { return "Unknown" }
        let text = expiresAt.formatted(.iso8601)
        return credentials.isExpired(at: now()) ? "Expired at \(text)" : text
    }
}

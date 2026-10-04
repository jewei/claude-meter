import Foundation
import MeterDomain
import MeterPlatform

/// Token counts for the Cursor account, from Cursor's usage export for the last seven days.
///
/// Uses the login that the Cursor app stores, read-only. The history describes the account,
/// not this Mac, and has one account, ``AccountID/default``.
///
/// A failure may keep the previous history only while that history belongs to the signed-in
/// login, the rule that quota follows. ``TokenHistoryProvider`` hands in neither the previous
/// history nor its owner, so this type cannot see whose history the app holds. It keeps only
/// what proves it: the logins whose history it ever returned. While that set is exactly the
/// signed-in login, the held history, if any, is that login's. After a login change the set
/// has two logins, so later failures clear the history instead of showing another login's
/// tokens.
public final class CursorTokenHistory: TokenHistoryProvider {
    private static let log = Log(.cursor)

    private let store: CursorCredentialStore
    private let http: any HTTPClient
    /// Read once per call, so a time zone change applies to the next read.
    private let calendar: @Sendable () -> Calendar
    /// Every login whose history this value returned. The app can discard a returned history,
    /// so this is a superset of the owner of the history that the app holds. It only grows, so
    /// it can drop a history that could stay, but never keeps one of another login.
    private let returnedOwners = Locked<Set<AccountOwner>>([])
    /// The retry time of the last HTTP 429. No export is sent before it.
    private let retryAt = Locked<Date?>(nil)
    /// The last failure, so that the log records changes only.
    private let lastFailure = Locked<CursorFailure?>(nil)

    /// - Parameters:
    ///   - keychain: Read only, for the access token when the state database has none.
    ///   - http: Sends the export request.
    ///   - home: The user's home directory, which holds Cursor's state database.
    ///   - calendar: Assigns token records to local days. The default follows the system
    ///     time zone at each read.
    public convenience init(
        keychain: any Keychain = SystemKeychain(),
        http: any HTTPClient = URLSessionHTTPClient.shared,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.init(keychain: keychain, http: http, home: home, calendar: { calendar })
    }

    /// Tests pass a calendar that changes between reads.
    init(
        keychain: any Keychain, http: any HTTPClient, home: URL,
        calendar: @escaping @Sendable () -> Calendar
    ) {
        self.store = CursorCredentialStore(
            home: home, keychain: keychain, readTimeout: CursorCredentialStore.historyReadTimeout)
        self.http = http
        self.calendar = calendar
    }

    /// Always ``ProviderID/cursor``.
    public var id: ProviderID { .cursor }

    /// Reads token history for today and the previous six local days.
    ///
    /// Throws ``ProviderError``, which keeps the previous history only while it provably
    /// belongs to the signed-in login, or `CancellationError`. A response that arrives after
    /// the login changed is discarded.
    public func history(now: Date) async throws -> ProviderTokenHistory {
        let credentials: CursorCredentials
        switch try await store.read() {
        case .found(let found):
            credentials = found
        case .missing:
            throw failure(.signedOut, status: .signedOut)
        case .unreadable(let failure):
            throw self.failure(failure, status: .unknown)
        }
        let owner = credentials.owner
        if let retryAt = retryAt.value, retryAt > now {
            throw failure(.rateLimited(retryAt: retryAt), status: .signedIn(owner))
        }
        let result: Result<ProviderTokenHistory, CursorFailure>
        do {
            result = .success(try await export(credentials, now: now))
        } catch let failure as CursorFailure {
            result = .failure(failure)
        }
        // The response belongs to the login that sent it. Discard it if the login changed.
        let after = try await store.read().ownerStatus
        switch after {
        case .signedOut:
            throw failure(.signedOut, status: after)
        case .signedIn(let current) where current != owner:
            throw failure(.signInChanged, status: after)
        case .signedIn, .unknown:
            break
        }
        switch result {
        case .success(let history):
            returnedOwners.withLock { _ = $0.insert(owner) }
            retryAt.withLock { $0 = nil }
            let recovered = lastFailure.withLock { last in
                defer { last = nil }
                return last != nil
            }
            if recovered { Self.log.notice("Cursor token history recovered.") }
            return history
        case .failure(let failure):
            if case .rateLimited(let date?) = failure { retryAt.withLock { $0 = date } }
            throw self.failure(failure, status: .signedIn(owner))
        }
    }

    /// Throws ``CursorFailure`` or `CancellationError`.
    private func export(_ credentials: CursorCredentials, now: Date) async throws
        -> ProviderTokenHistory
    {
        guard !credentials.isExpired(at: now) else { throw CursorFailure.sessionExpired }
        // One fixed zone for the range, the days, and the label, even if the system zone
        // changes during the read.
        let current = calendar()
        var calendar = Calendar(identifier: current.identifier)
        calendar.timeZone = current.timeZone
        guard let range = TokenPeriod.lastSevenDays.interval(at: now, calendar: calendar) else {
            throw CursorFailure.invalidDate
        }
        let request = try CursorAPI.exportRequest(credentials: credentials, range: range, now: now)
        let body = try await CursorAPI.send(request, http: http, now: now)
        let history = try CursorTokenCSV.history(body, range: range, now: now, calendar: calendar)
        try Task.checkCancellation()
        return ProviderTokenHistory(
            provider: .cursor, source: .account, accounts: [.default: history],
            coverageStart: range.start, observedAt: now, timeZoneID: calendar.timeZone.identifier)
    }

    /// The error for `failure` while the login is `status`. The previous history stays only
    /// while the login cannot be read, or while every history returned so far belongs to the
    /// signed-in login: the rule of ``AccountUsage/belongs(to:)``, applied to a history whose
    /// owner this type can only bound.
    private func failure(_ failure: CursorFailure, status: OwnerStatus) -> ProviderError {
        let isNew = lastFailure.withLock { last in
            defer { last = failure }
            return last != failure
        }
        if isNew {
            Self.log.warning("Cursor token history failed: \(failure.issue.message)")
        }
        let belongs: Bool
        switch status {
        case .unknown: belongs = true
        case .signedOut: belongs = false
        case .signedIn(let current): belongs = returnedOwners.value == [current]
        }
        return ProviderError(failure.issue, keepsLastReading: belongs && failure.keepsObservation)
    }
}

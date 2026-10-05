import Foundation
import MeterDomain
import MeterPlatform

/// Token counts for the Cursor account, from Cursor's usage export for the last seven days.
///
/// Uses the login that the Cursor app stores, read-only. The history describes the account,
/// not this Mac, and has one account, ``AccountID/default``.
///
/// Each history carries the owner of the login that read it. A failure keeps the history that
/// the app holds only while ``ProviderTokenHistory/belongs(to:)`` allows it: the same rule as
/// quota.
public final class CursorTokenHistory: TokenHistoryProvider {
    private static let log = Log(.cursor)

    private let store: CursorCredentialStore
    private let http: any HTTPClient
    /// Read once per call, so a time zone change applies to the next read.
    private let calendar: @Sendable () -> Calendar
    /// The pause after HTTP 429 for each login (``RateLimitHolds``). A hold stops only the
    /// exports of the login that got it, and a 429 for another login never ends it. The app
    /// holds no history issue for the provider, so the holds live here, in memory only.
    private let holds = Locked(RateLimitHolds())
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

    /// Drops a held history whose login is no longer signed in. Reads only local credentials.
    public func reconcile(_ previous: ProviderTokenHistory?) async -> ProviderTokenHistory? {
        guard let previous else { return nil }
        let status = (try? await store.read().ownerStatus) ?? .unknown
        return previous.belongs(to: status) ? previous : nil
    }

    /// Reads token history for today and the previous six local days.
    ///
    /// Throws ``ProviderError``, which keeps `previous` only while it belongs to the signed-in
    /// login, or `CancellationError`. A response that arrives after the login changed is
    /// discarded.
    public func history(now: Date, previous: ProviderTokenHistory?) async throws
        -> ProviderTokenHistory
    {
        let credentials: CursorCredentials
        switch try await store.read() {
        case .found(let found):
            credentials = found
        case .missing:
            throw failure(.signedOut, status: .signedOut, previous: previous)
        case .unreadable(let failure):
            throw self.failure(failure, status: .unknown, previous: previous)
        }
        let owner = credentials.owner
        if let retryAt = holds.value.retryAt(for: owner, now: now) {
            throw failure(
                .rateLimited(retryAt: retryAt), status: .signedIn(owner), previous: previous)
        }
        let result: Result<ProviderTokenHistory, CursorFailure>
        do {
            result = .success(try await export(credentials, now: now))
        } catch let failure as CursorFailure {
            result = .failure(failure)
        }
        // The 429 belongs to the login that sent the export, even if the login changes now.
        if case .failure(.rateLimited(let retryAt?)) = result {
            holds.withLock { $0.record(RateLimitHold(owner: owner, retryAt: retryAt), now: now) }
        }
        // The response belongs to the login that sent it. Discard it if the login changed.
        let after = try await store.read().ownerStatus
        switch after {
        case .signedOut:
            throw failure(.signedOut, status: after, previous: previous)
        case .signedIn(let current) where current != owner:
            throw failure(.signInChanged, status: after, previous: previous)
        case .signedIn, .unknown:
            break
        }
        switch result {
        case .success(let history):
            let recovered = lastFailure.withLock { last in
                defer { last = nil }
                return last != nil
            }
            if recovered { Self.log.notice("Cursor token history recovered.") }
            return history
        case .failure(let failure):
            throw self.failure(failure, status: .signedIn(owner), previous: previous)
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
            coverageStart: range.start, observedAt: now, timeZoneID: calendar.timeZone.identifier,
            owner: credentials.owner)
    }

    /// The error for `failure` while the login is `status`. The held history stays only while
    /// it belongs to that login.
    private func failure(
        _ failure: CursorFailure, status: OwnerStatus, previous: ProviderTokenHistory?
    ) -> ProviderError {
        let isNew = lastFailure.withLock { last in
            defer { last = failure }
            return last != failure
        }
        if isNew {
            Self.log.warning("Cursor token history failed: \(failure.issue.message)")
        }
        let belongs = previous?.belongs(to: status) ?? false
        return ProviderError(failure.issue, keepsLastReading: belongs && failure.keepsObservation)
    }
}

import Foundation
import MeterDomain
import MeterPlatform

/// Token counts for the Cursor account, from Cursor's usage export for the last seven days.
///
/// Uses the login that the Cursor app stores, read-only. The history describes the account,
/// not this Mac, and has one account, ``AccountID/default``.
public final class CursorTokenHistory: TokenHistoryProvider {
    private static let log = Log(.cursor)

    private let store: CursorCredentialStore
    private let http: any HTTPClient
    /// Read once per call, so a time zone change applies to the next read.
    private let calendar: @Sendable () -> Calendar
    /// The login of the last history returned. A failure keeps the previous history only
    /// while this login is still signed in.
    private let lastOwner = Locked<AccountOwner?>(nil)
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
        self.store = CursorCredentialStore(home: home, keychain: keychain)
        self.http = http
        self.calendar = calendar
    }

    public var id: ProviderID { .cursor }

    /// Reads token history for today and the previous six local days.
    ///
    /// Throws ``ProviderError``, which keeps the previous history only while the same login is
    /// signed in, or `CancellationError`. A response that arrives after the login changed is
    /// discarded.
    public func history(now: Date) async throws -> ProviderTokenHistory {
        let credentials: CursorCredentials
        switch try await store.read() {
        case .found(let found):
            credentials = found
        case .missing:
            throw failure(.signedOut, keepsLastReading: false)
        case .unreadable(let failure):
            throw self.failure(failure, keepsLastReading: true)
        }
        let owner = credentials.owner
        let isSameLogin = lastOwner.value == owner
        do {
            let history = try await export(credentials, now: now)
            switch try await store.read().ownerStatus {
            case .signedOut: throw CursorFailure.signedOut
            case .signedIn(let current) where current != owner: throw CursorFailure.signInChanged
            case .signedIn, .unknown: break
            }
            lastOwner.withLock { $0 = owner }
            lastFailure.withLock { $0 = nil }
            return history
        } catch let failure as CursorFailure {
            let keeps = isSameLogin && failure != .signedOut && failure != .signInChanged
            throw self.failure(failure, keepsLastReading: keeps)
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

    private func failure(_ failure: CursorFailure, keepsLastReading: Bool) -> ProviderError {
        let isNew = lastFailure.withLock { last in
            defer { last = failure }
            return last != failure
        }
        if isNew {
            Self.log.warning("Cursor token history failed: \(failure.issue.message)")
        }
        return ProviderError(failure.issue, keepsLastReading: keepsLastReading)
    }
}

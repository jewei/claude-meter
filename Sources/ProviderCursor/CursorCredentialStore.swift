import Foundation
import MeterDomain
import MeterPlatform

/// Reads Cursor's login from its state database, with a read-only Keychain fallback.
///
/// The app never writes, renews, or caches Cursor credentials. Every call reads again, so a
/// login change in Cursor shows at the next read.
struct CursorCredentialStore: Sendable {
    /// The state of the SQLite database at the last read, for Diagnostics.
    enum DatabaseState: String, Sendable {
        case found = "Found"
        case missing = "Missing"
        case busy = "Busy"
        case unreadable = "Unreadable"
        /// The database or Keychain read did not finish in time.
        case timedOut = "Not read in time"
    }

    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let emailKey = "cursorAuth/cachedEmail"
    static let membershipKey = "cursorAuth/stripeMembershipType"
    static let query = "SELECT key, value FROM ItemTable WHERE key IN (?, ?, ?, ?) LIMIT 4"
    static let keys = [accessTokenKey, refreshTokenKey, emailKey, membershipKey]
    /// The Keychain item that holds the access token when the database has none.
    static let accessTokenService = "cursor-access-token"
    static let readTimeout: Duration = .seconds(5)

    let database: URL
    private let keychain: any Keychain
    private let readTimeout: Duration

    /// - Parameter readTimeout: The limit for one blocking read. Tests pass less.
    init(home: URL, keychain: any Keychain, readTimeout: Duration = Self.readTimeout) {
        self.database = Self.databaseURL(home: home)
        self.keychain = keychain
        self.readTimeout = readTimeout
    }

    static func databaseURL(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Reads the login. Throws only `CancellationError`.
    func read() async throws -> CursorCredentialLookup {
        try await inspect().lookup
    }

    /// Reads the login and reports the database state. Throws only `CancellationError`.
    func inspect() async throws -> (database: DatabaseState, lookup: CursorCredentialLookup) {
        try await runBlocking(whenBusy: (.timedOut, .unreadable(.credentialsTimedOut))) {
            [database, keychain] cancellation in
            let (values, state) = Self.databaseValues(database, cancellation: cancellation)
            if cancellation.isCancelled { throw CancellationError() }
            return (state, Self.resolve(values, state: state, keychain: keychain))
        }
    }

    /// Whether a login exists, without reading the Keychain secret. Sends nothing.
    ///
    /// Follows the same order as ``read()``: a busy or unreadable database proves nothing, so
    /// the Keychain is not asked.
    func signInStatus() async throws -> SignInStatus {
        try await runBlocking(whenBusy: .unknown(CursorFailure.credentialsTimedOut.issue.message)) {
            [database, keychain] cancellation in
            let (values, state) = Self.databaseValues(database, cancellation: cancellation)
            if cancellation.isCancelled { throw CancellationError() }
            if values[Self.accessTokenKey] != nil { return .signedIn }
            if let failure = Self.failure(for: state) { return .unknown(failure.issue.message) }
            do throws(KeychainError) {
                let items = try keychain.items(
                    servicePrefix: Self.accessTokenService, account: nil)
                let exists = items.contains { $0.service == Self.accessTokenService }
                return exists ? .signedIn : .signedOut
            } catch {
                return .unknown(Self.failure(for: error).issue.message)
            }
        }
    }

    // MARK: - Reading

    private func runBlocking<Value: Sendable>(
        whenBusy busy: Value,
        _ work: @escaping @Sendable (BlockingIO.Cancellation) throws -> Value
    ) async throws -> Value {
        do {
            return try await BlockingIO.run(timeout: readTimeout, work)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A timeout or a full blocking-I/O pool is temporary.
            return busy
        }
    }

    /// The four values that Cursor stores, decoded. A missing database is not an error.
    private static func databaseValues(
        _ database: URL, cancellation: BlockingIO.Cancellation
    ) -> ([String: String], DatabaseState) {
        // SQLite opens the sidecars of the link's target, so the sidecar check must see the
        // target too. Otherwise a FIFO next to the target blocks the open.
        let target = database.resolvingSymlinksInPath()
        let rows: [[Data?]]
        do {
            rows = try SQLiteReader.rows(
                in: target, query: query, bindings: keys, cancellation: cancellation)
        } catch .notFound {
            return ([:], .missing)
        } catch .busy {
            return ([:], .busy)
        } catch {
            return ([:], .unreadable)
        }
        var values: [String: String] = [:]
        for row in rows where row.count == 2 {
            guard let keyData = row[0], let key = String(data: keyData, encoding: .utf8),
                let valueData = row[1], let value = CursorStoredValue.text(valueData)
            else { continue }
            values[key] = value
        }
        return (values, .found)
    }

    /// The database wins. The Keychain is read only when the database was read and has no
    /// access token: a busy or unreadable database can still hold a token, and the Keychain item
    /// can belong to another login, such as the `cursor-agent` CLI.
    private static func resolve(
        _ values: [String: String], state: DatabaseState, keychain: any Keychain
    ) -> CursorCredentialLookup {
        if let failure = failure(for: state) { return .unreadable(failure) }
        let membership = values[membershipKey]
        let hasRefreshToken = values[refreshTokenKey] != nil
        if let token = values[accessTokenKey] {
            return .found(
                CursorCredentials(
                    accessToken: token, membership: membership, source: .database,
                    hasRefreshToken: hasRefreshToken))
        }
        let stored: Data?
        do {
            stored = try keychain.password(service: accessTokenService, account: nil)
        } catch {
            return .unreadable(failure(for: error))
        }
        guard let stored else { return .missing }
        // The item exists, so `signInStatus` says signed in. An item without a usable token is
        // unreadable, not a sign-out, so the card and onboarding agree.
        guard let token = CursorStoredValue.text(stored) else {
            return .unreadable(.credentialsUnreadable)
        }
        return .found(
            CursorCredentials(
                accessToken: token, membership: membership, source: .keychain,
                hasRefreshToken: hasRefreshToken))
    }

    private static func failure(for state: DatabaseState) -> CursorFailure? {
        switch state {
        case .found, .missing: nil
        case .busy: .credentialsBusy
        case .unreadable: .credentialsUnreadable
        case .timedOut: .credentialsTimedOut
        }
    }

    private static func failure(for error: KeychainError) -> CursorFailure {
        switch error {
        case .unavailable: .keychainUnavailable
        case .denied: .keychainDenied
        case .failure: .keychainFailed
        }
    }
}

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

    init(home: URL, keychain: any Keychain) {
        self.database = Self.databaseURL(home: home)
        self.keychain = keychain
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
        try await runBlocking(whenBusy: (.busy, .unreadable(.credentialsBusy))) {
            [database, keychain] cancellation in
            let (values, state) = Self.databaseValues(database, cancellation: cancellation)
            if cancellation.isCancelled { throw CancellationError() }
            return (state, Self.resolve(values, state: state, keychain: keychain))
        }
    }

    /// Whether a login exists, without reading the Keychain secret. Sends nothing.
    func signInStatus() async throws -> SignInStatus {
        try await runBlocking(whenBusy: .unknown(CursorFailure.credentialsBusy.issue.message)) {
            [database, keychain] cancellation in
            let (values, state) = Self.databaseValues(database, cancellation: cancellation)
            if cancellation.isCancelled { throw CancellationError() }
            if values[Self.accessTokenKey] != nil { return .signedIn }
            do {
                let items = try keychain.items(
                    servicePrefix: Self.accessTokenService, account: nil)
                if items.contains(where: { $0.service == Self.accessTokenService }) {
                    return .signedIn
                }
            } catch {
                return .unknown(
                    (Self.failure(for: state) ?? .keychainUnavailable).issue.message)
            }
            if let failure = Self.failure(for: state) { return .unknown(failure.issue.message) }
            return .signedOut
        }
    }

    // MARK: - Reading

    private func runBlocking<Value: Sendable>(
        whenBusy busy: Value,
        _ work: @escaping @Sendable (BlockingIO.Cancellation) throws -> Value
    ) async throws -> Value {
        do {
            return try await BlockingIO.run(timeout: Self.readTimeout, work)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A timeout or a full blocking-I/O pool is temporary, like a SQLite lock.
            return busy
        }
    }

    /// The four values that Cursor stores, decoded. A missing database is not an error.
    private static func databaseValues(
        _ database: URL, cancellation: BlockingIO.Cancellation
    ) -> ([String: String], DatabaseState) {
        let rows: [[Data?]]
        do {
            rows = try SQLiteReader.rows(
                in: database, query: query, bindings: keys, cancellation: cancellation)
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

    /// The database wins. The Keychain is read only when the database has no access token.
    private static func resolve(
        _ values: [String: String], state: DatabaseState, keychain: any Keychain
    ) -> CursorCredentialLookup {
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
            return .unreadable(failure(for: state) ?? .keychainUnavailable)
        }
        if let token = stored.flatMap(CursorStoredValue.text) {
            return .found(
                CursorCredentials(
                    accessToken: token, membership: membership, source: .keychain,
                    hasRefreshToken: hasRefreshToken))
        }
        if let failure = failure(for: state) { return .unreadable(failure) }
        return .missing
    }

    private static func failure(for state: DatabaseState) -> CursorFailure? {
        switch state {
        case .found, .missing: nil
        case .busy: .credentialsBusy
        case .unreadable: .credentialsUnreadable
        }
    }
}

import ClaudeMeterCore
import Darwin
import Foundation
import SQLite3

public struct CursorCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let email: String?
    public let membership: String?
}

enum CursorCredentialReadError: Error, LocalizedError, Equatable {
    case busy
    case unavailable

    var errorDescription: String? {
        switch self {
        case .busy: "Cursor credential database is busy. Try again shortly."
        case .unavailable: "Could not read Cursor credentials. Open Cursor and try again."
        }
    }
}

/// Reads Cursor's locally-stored auth from `state.vscdb` (the editor's
/// VS Code-style key/value store), with a macOS Keychain fallback. Cursor keeps
/// the access/refresh tokens here; we only ever read them.
public enum CursorTokenStore {

    /// macOS path to Cursor's global key/value SQLite store.
    static var stateDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            )
            .path
    }

    private static let stateKeys = [
        "cursorAuth/accessToken",
        "cursorAuth/refreshToken",
        "cursorAuth/cachedEmail",
        "cursorAuth/stripeMembershipType",
    ]

    /// No credential detection cache. Temporary read failures remain distinct from absence.
    public static func detect() throws -> CursorCredentials? {
        try load(stateDatabasePath: stateDBPath, keychainLoader: keychainValue(service:))
    }

    static func load(
        stateDatabasePath: String, keychainLoader: (String) -> String?
    ) throws -> CursorCredentials? {
        try Task.checkCancellation()
        var values: [String: String] = [:]
        var readError: Error?
        do {
            values = try readStateValues(stateDatabasePath: stateDatabasePath)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            readError = error
        }
        try Task.checkCancellation()
        let credentials = resolveCredentials(stateValues: values, keychainLoader: keychainLoader)
        try Task.checkCancellation()
        if let credentials { return credentials }
        if let readError { throw readError }
        return nil
    }

    static func resolveCredentials(
        stateValues: [String: String], keychainLoader: (String) -> String?
    ) -> CursorCredentials? {
        func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let access =
            nonEmpty(stateValues["cursorAuth/accessToken"])
            ?? nonEmpty(keychainLoader("cursor-access-token"))
        let refresh =
            nonEmpty(stateValues["cursorAuth/refreshToken"])
            ?? nonEmpty(keychainLoader("cursor-refresh-token"))
        return access.map {
            CursorCredentials(
                accessToken: $0, refreshToken: refresh,
                email: nonEmpty(stateValues["cursorAuth/cachedEmail"]),
                membership: nonEmpty(stateValues["cursorAuth/stripeMembershipType"]?.lowercased()))
        }
    }

    /// Filesystem evidence only; onboarding must not read secrets.
    public static func isStateDBPresent() -> Bool {
        (try? regularFileExists(atPath: stateDBPath)) == true
    }

    // Reject devices/FIFOs before SQLite opens them. No file identity or content cache.
    private static func regularFileExists(atPath path: String) throws -> Bool {
        var status = stat()
        guard Darwin.fstatat(AT_FDCWD, path, &status, 0) == 0 else {
            if errno == ENOENT { return false }
            throw CursorCredentialReadError.unavailable
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw CursorCredentialReadError.unavailable
        }
        return true
    }

    // MARK: - JWT expiry

    /// The access token is a JWT; returns its `exp` as a `Date` when decodable.
    public static func expiry(of accessToken: String) -> Date? {
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2,
            let payload = base64URLDecode(String(parts[1])),
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let exp = (object["exp"] as? NSNumber)?.doubleValue,
            exp.isFinite
        else { return nil }
        return boundedProviderDate(timeIntervalSince1970: exp)
    }

    /// True when the token is missing an expiry, already expired, or expires
    /// within `buffer` seconds (default 5 minutes — matches Cursor's own buffer).
    public static func isExpiringSoon(
        _ accessToken: String, buffer: TimeInterval = 300, now: Date = Date()
    ) -> Bool {
        guard let exp = expiry(of: accessToken) else { return true }
        return exp.timeIntervalSince(now) < buffer
    }

    // MARK: - SQLite read

    /// Called off-main by provider execution or Settings' detached task.
    static func readStateValues(stateDatabasePath: String) throws -> [String: String] {
        try Task.checkCancellation()
        guard try regularFileExists(atPath: stateDatabasePath) else { return [:] }
        let url = URL(fileURLWithPath: stateDatabasePath).resolvingSymlinksInPath()
        for suffix in ["-wal", "-shm", "-journal"] {
            _ = try regularFileExists(atPath: url.path + suffix)
        }
        // SQLite's Unix VFS uses readonly_shm to prohibit SHM creation/recovery writes.
        // Keep normal locking/WAL semantics. Never assert immutable for Cursor's live DB.
        var uri = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        uri.queryItems = [URLQueryItem(name: "readonly_shm", value: "1")]
        var database: OpaquePointer?
        defer { if let database { sqlite3_close(database) } }
        try checkSQLite(
            sqlite3_open_v2(uri.string!, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil))
        guard let database else { throw CursorCredentialReadError.unavailable }
        // Bound individual rows. Busy readers fail promptly; the provider's existing
        // timeout bounds filesystem work, and cancellation interrupts long query scans.
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1_024 * 1_024)
        sqlite3_progress_handler(database, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try checkSQLite(
            sqlite3_prepare_v2(
                database, "SELECT key, value FROM ItemTable WHERE key IN (?, ?, ?, ?) LIMIT 4",
                -1, &statement, nil))
        for (index, key) in stateKeys.enumerated() {
            let result = key.withCString {
                sqlite3_bind_text(
                    statement, Int32(index + 1), $0, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            try checkSQLite(result)
        }
        var values: [String: String] = [:]
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            try checkSQLite(result)
            guard let keyBytes = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: keyBytes)
            // SQLite converts TEXT from the database encoding to UTF-8. BLOBs
            // retain their bytes for Cursor's stored-value decoding below.
            let bytes: UnsafeRawPointer?
            if sqlite3_column_type(statement, 1) == SQLITE_TEXT {
                bytes = sqlite3_column_text(statement, 1).map(UnsafeRawPointer.init)
            } else {
                bytes = sqlite3_column_blob(statement, 1)
            }
            guard let bytes else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            if let decoded = decodeStoredValue(data) {
                let value = unquoteStoredValue(decoded)
                if !value.isEmpty { values[key] = value }
            }
        }
    }

    private static func checkSQLite(_ result: Int32) throws {
        try Task.checkCancellation()
        switch result & 0xff {
        case SQLITE_OK, SQLITE_ROW, SQLITE_DONE: return
        case SQLITE_BUSY, SQLITE_LOCKED: throw CursorCredentialReadError.busy
        default: throw CursorCredentialReadError.unavailable
        }
    }

    static func decodeStoredValue(_ data: Data) -> String? {
        // A BLOB may contain BOM-less ASCII UTF-16LE. Test this before UTF-8,
        // which would accept its NUL bytes as part of the token.
        let bytes = Array(data)
        if !bytes.isEmpty, bytes.count.isMultiple(of: 2),
            stride(from: 0, to: bytes.count, by: 2).allSatisfy({
                bytes[$0] > 0 && bytes[$0] < 128 && bytes[$0 + 1] == 0
            })
        {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Reads a Cursor-owned Keychain item through the shared no-UI gateway.
    ///
    /// Deliberately *not* `/usr/bin/security find-generic-password -w`: that is a
    /// secret read with no non-interactive policy, so an item whose ACL doesn't
    /// list this app raises the legacy Allow/Deny dialog and blocks the subprocess
    /// until the user answers — and it sidesteps the fail-closed test gateway,
    /// letting a unit test touch the developer's real login Keychain. Same policy
    /// `OAuthKeychain` applies to Claude Code's items.
    private static func keychainValue(service: String) -> String? {
        guard let value = KeychainGateway.readGenericPassword(service: service) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : unquoteStoredValue(trimmed)
    }

    // MARK: - Helpers

    static func base64URLDecode(_ string: String) -> Data? {
        Base64URL.decode(string)
    }

    static func unquoteStoredValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
            trimmed.hasPrefix("\""),
            trimmed.hasSuffix("\"")
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

}

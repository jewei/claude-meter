import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import SQLite3

/// A temporary home directory with Cursor's state database, built with real SQLite.
struct CursorHome {
    enum Value {
        case text(String)
        case blob(Data)
    }

    struct SQLiteError: Error {
        let code: Int32
    }

    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    var url: URL { directory.url }

    var database: URL {
        directory.path("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    func remove() {
        directory.remove()
    }

    /// Creates or replaces the database with `values` in `ItemTable`. `encoding` is the text
    /// encoding of the new database, such as `UTF-16le`.
    func write(
        _ values: [String: Value], journalMode: String = "WAL", encoding: String = "UTF-8"
    ) throws {
        let folder = database.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
        }
        let handle = try open()
        defer { sqlite3_close(handle) }
        try execute(handle, "PRAGMA encoding = '\(encoding)';")
        try execute(handle, "PRAGMA journal_mode=\(journalMode);")
        try execute(
            handle, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        for (key, value) in values {
            var statement: OpaquePointer?
            try check(
                sqlite3_prepare_v2(
                    handle, "INSERT INTO ItemTable VALUES (?, ?);", -1, &statement, nil))
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_text(statement, 1, key, -1, transient))
            switch value {
            case .text(let text):
                try check(sqlite3_bind_text(statement, 2, text, -1, transient))
            case .blob(let data):
                try data.withUnsafeBytes { bytes in
                    try check(
                        sqlite3_bind_blob(
                            statement, 2, bytes.baseAddress, Int32(bytes.count), transient))
                }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteError(code: -1) }
        }
    }

    /// Writes a database with the access token and optional plan as text.
    func write(token: String, membership: String? = nil) throws {
        var values: [String: Value] = [
            "cursorAuth/accessToken": .text(token),
            "cursorAuth/refreshToken": .text("refresh-token"),
            "cursorAuth/cachedEmail": .text("alpha@example.com"),
        ]
        if let membership { values["cursorAuth/stripeMembershipType"] = .text(membership) }
        try write(values)
    }

    /// Holds an exclusive lock until the returned handle is closed. Use a rollback journal,
    /// because WAL readers do not wait for writers.
    func lockExclusively() throws -> OpaquePointer {
        let handle = try open()
        try execute(handle, "BEGIN EXCLUSIVE;")
        return handle
    }

    func unlock(_ handle: OpaquePointer) {
        sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
        sqlite3_close(handle)
    }

    /// Replaces the access token in a transaction that stays open until ``commit(_:)``, as
    /// Cursor does while it writes.
    func beginWrite(token: String) throws -> OpaquePointer {
        let handle = try open()
        try execute(handle, "BEGIN IMMEDIATE;")
        var statement: OpaquePointer?
        try check(
            sqlite3_prepare_v2(
                handle, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?);", -1,
                &statement, nil))
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_text(statement, 1, token, -1, transient))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteError(code: -1) }
        return handle
    }

    func commit(_ handle: OpaquePointer) {
        sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
        sqlite3_close(handle)
    }

    private func open() throws -> OpaquePointer {
        var handle: OpaquePointer?
        let status = sqlite3_open(database.path, &handle)
        guard status == SQLITE_OK, let handle else { throw SQLiteError(code: status) }
        return handle
    }

    private func execute(_ handle: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    private func check(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw SQLiteError(code: status) }
    }

    private var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}

/// Recorded Cursor responses and tokens.
enum CursorFixture {
    /// The header of the usage export, with the columns that Cursor sends.
    static let csvHeader =
        "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost"

    static let usage = """
        {"billingCycleStart":"1750000000000","billingCycleEnd":"1752592200000","planUsage":{"totalSpend":1240,"limit":2000,"autoPercentUsed":10.0,"apiPercentUsed":100.0,"totalPercentUsed":62.0},"enabled":true}
        """

    /// A JWT like Cursor's, valid for an hour after the reference date by default.
    static func token(
        subject: String? = "auth0|user_123", expiresAt: Date = .reference(.hours(1))
    ) -> String {
        var extra: [String: Any] = [:]
        if let subject { extra["sub"] = subject }
        return JWTFixture.token(expiresAt: expiresAt, extra: extra)
    }

    static func ownerOf(subject: String) -> AccountOwner {
        .identity(Digest.sha256(parts: ["cursor", subject]))
    }
}

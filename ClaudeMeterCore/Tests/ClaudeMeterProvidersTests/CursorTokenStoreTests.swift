import ClaudeMeterCore
import Darwin
import Foundation
import SQLite3
import Testing

@testable import ClaudeMeterProviders

@Suite("Cursor direct SQLite credentials")
struct CursorTokenStoreTests {
    private final class Database {
        let directory: URL
        let url: URL
        var connection: OpaquePointer?

        init(table: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("state.vscdb")
            try Self.check(sqlite3_open(url.path, &connection))
            if table { try exec("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)") }
        }

        deinit {
            sqlite3_close(connection)
            try? FileManager.default.removeItem(at: directory)
        }

        func close() throws {
            try Self.check(sqlite3_close(connection))
            connection = nil
        }

        func exec(_ sql: String) throws {
            try Self.check(sqlite3_exec(connection, sql, nil, nil, nil))
        }

        func put(_ key: String, _ data: Data) throws {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try Self.check(
                sqlite3_prepare_v2(
                    connection, "INSERT OR REPLACE INTO ItemTable VALUES (?, ?)", -1, &statement,
                    nil))
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try Self.check(key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) })
            try Self.check(
                data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient)
                })
            try Self.check(sqlite3_step(statement))
        }

        func token(_ text: String) throws {
            try put("cursorAuth/accessToken", Data(text.utf8))
        }

        func read() throws -> CursorCredentials? {
            try CursorTokenStore.load(stateDatabasePath: url.path, keychainLoader: { _ in nil })
        }

        static func check(_ code: Int32) throws {
            guard code == SQLITE_OK || code == SQLITE_DONE else { throw FixtureError.sqlite(code) }
        }
    }

    private enum FixtureError: Error { case sqlite(Int32) }

    @Test func allKeysAndReadOnlyFiles() throws {
        let db = try Database()
        try db.token("\"access\"")
        try db.put("cursorAuth/refreshToken", Data("refresh".utf8))
        try db.put("cursorAuth/cachedEmail", Data("test@example.invalid".utf8))
        try db.put("cursorAuth/stripeMembershipType", Data("PRO".utf8))
        try db.close()
        let before = try Data(contentsOf: db.url)
        let attributes = try FileManager.default.attributesOfItem(atPath: db.url.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: db.directory.path)
        #expect(
            try db.read()
                == CursorCredentials(
                    accessToken: "access", refreshToken: "refresh", email: "test@example.invalid",
                    membership: "pro"))
        #expect(try Data(contentsOf: db.url) == before)
        let after = try FileManager.default.attributesOfItem(atPath: db.url.path)
        for key: FileAttributeKey in [
            .modificationDate, .size, .systemFileNumber, .posixPermissions,
        ] {
            #expect((attributes[key] as? NSObject) == (after[key] as? NSObject))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: db.directory.path) == files)
    }

    @Test func accessOnlyAndMissingAccess() throws {
        let db = try Database()
        #expect(try db.read() == nil)
        try db.put("cursorAuth/refreshToken", Data("refresh".utf8))
        #expect(try db.read() == nil)
        try db.exec("DELETE FROM ItemTable")
        try db.token("access")
        #expect(
            try db.read()
                == CursorCredentials(
                    accessToken: "access", refreshToken: nil, email: nil, membership: nil))
    }

    @Test func missingDatabaseFallsBackWithoutCreatingFiles() throws {
        let db = try Database()
        let missing = db.directory.appendingPathComponent("missing.vscdb")
        #expect(
            try CursorTokenStore.load(stateDatabasePath: missing.path, keychainLoader: { _ in nil })
                == nil)
        #expect(
            try CursorTokenStore.load(
                stateDatabasePath: missing.path, keychainLoader: { _ in "fallback" })?.accessToken
                == "fallback")
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func unusableDatabaseAllowsKeychainFallback() throws {
        let db = try Database(table: false)
        #expect(throws: CursorCredentialReadError.unavailable) { try db.read() }
        try db.close()
        // Also exercise an invalid SQLite header.
        try Data("not a database".utf8).write(to: db.url)
        #expect(throws: CursorCredentialReadError.unavailable) { try db.read() }
        #expect(
            try CursorTokenStore.load(
                stateDatabasePath: db.url.path, keychainLoader: { _ in "fallback" })?.accessToken
                == "fallback")
    }

    @Test func encodingsAndLiteralValues() throws {
        let db = try Database()
        for data in [
            Data("token".utf8),
            "token".data(using: .utf16LittleEndian)!,
            "token".data(using: .utf16)!,
            Data([0xfe, 0xff]) + "token".data(using: .utf16BigEndian)!,
        ] {
            try db.put("cursorAuth/accessToken", data)
            #expect(try db.read()?.accessToken == "token")
        }
        try db.token("token|with\nseparators'?")
        #expect(try db.read()?.accessToken == "token|with\nseparators'?")
        for data in [Data([0xff]), Data([0xfe, 0xff, 0xd8, 0x00]), Data()] {
            try db.put("cursorAuth/accessToken", data)
            #expect(try db.read() == nil)
        }
    }

    @Test func textInUTF16Database() throws {
        let db = try Database(table: false)
        try db.exec(
            "PRAGMA encoding='UTF-16le'; CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'token'), ('cursorAuth/cachedEmail', '用戶@example.invalid')"
        )
        #expect(try db.read()?.accessToken == "token")
        #expect(try db.read()?.email == "用戶@example.invalid")
    }

    @Test func activeWALReadsCommittedUpdatesAndCheckpoint() throws {
        let db = try Database()
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try db.token("first")
        let mainBefore = try Data(contentsOf: db.url)
        let wal = URL(fileURLWithPath: db.url.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        #expect(try db.read()?.accessToken == "first")
        #expect(try Data(contentsOf: db.url) == mainBefore)
        #expect(try Data(contentsOf: wal) == walBefore)
        try db.exec("BEGIN IMMEDIATE")
        try db.token("second")
        #expect(try db.read()?.accessToken == "first")
        try db.exec("COMMIT")
        #expect(try db.read()?.accessToken == "second")
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        #expect(try db.read()?.accessToken == "second")
        // The owner may also leave WAL mode and remove its sidecars.
        try db.exec("PRAGMA journal_mode=DELETE")
        #expect(try db.read()?.accessToken == "second")
    }

    @Test func missingSHMIsNotCreatedByReader() throws {
        let db = try Database()
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try db.token("token")
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.close()
        // Simulate a WAL database whose owner removed sidecars. Never repair it here.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: db.url.path + suffix)
        }
        let before = try Data(contentsOf: db.url)
        #expect(throws: CursorCredentialReadError.unavailable) { try db.read() }
        #expect(try Data(contentsOf: db.url) == before)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: db.directory.path) == [
                "state.vscdb"
            ])
    }

    @Test func replacedDatabaseIsReadWithoutCache() throws {
        let old = try Database()
        try old.token("old")
        try old.close()
        #expect(try old.read()?.accessToken == "old")
        let new = try Database()
        try new.token("new")
        try new.close()
        try FileManager.default.removeItem(at: old.url)
        try FileManager.default.copyItem(at: new.url, to: old.url)
        #expect(try old.read()?.accessToken == "new")
    }

    @Test func busyDatabaseIsTransientAndClosesReader() throws {
        let db = try Database()
        try db.token("token")
        try db.exec("BEGIN EXCLUSIVE")
        #expect(throws: CursorCredentialReadError.busy) { try db.read() }
        #expect(
            try CursorTokenStore.load(
                stateDatabasePath: db.url.path, keychainLoader: { _ in "fallback" })?.accessToken
                == "fallback")
        try db.exec("ROLLBACK")
        #expect(try db.read()?.accessToken == "token")
    }

    @Test func unsuitablePathsAreRejected() throws {
        let db = try Database()
        try db.close()
        let fifo = db.directory.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        for path in [fifo.path, db.directory.path, "/dev/null"] {
            #expect(throws: CursorCredentialReadError.unavailable) {
                try CursorTokenStore.readStateValues(stateDatabasePath: path)
            }
        }
        #expect(mkfifo(db.url.path + "-wal", 0o600) == 0)
        #expect(throws: CursorCredentialReadError.unavailable) { try db.read() }
    }

    @Test func keychainFallbackIsSelectiveAndNeverCached() throws {
        var services: [String] = []
        let values = [
            "cursorAuth/accessToken": "db-access", "cursorAuth/refreshToken": "db-refresh",
        ]
        #expect(
            CursorTokenStore.resolveCredentials(stateValues: values) {
                services.append($0)
                return nil
            }?.accessToken == "db-access")
        #expect(services.isEmpty)
        #expect(
            CursorTokenStore.resolveCredentials(stateValues: ["cursorAuth/accessToken": "db-access"]
            ) {
                services.append($0)
                return "keychain-refresh"
            }?.refreshToken == "keychain-refresh")
        #expect(services == ["cursor-refresh-token"])
        services.removeAll()
        #expect(
            CursorTokenStore.resolveCredentials(stateValues: [
                "cursorAuth/refreshToken": "db-refresh"
            ]) {
                services.append($0)
                return "keychain-access"
            }?.accessToken == "keychain-access")
        #expect(services == ["cursor-access-token"])
        let db = try Database()
        for token in ["keychain-one", "keychain-two"] {
            #expect(
                try CursorTokenStore.load(
                    stateDatabasePath: db.url.path, keychainLoader: { _ in token })?.accessToken
                    == token)
        }
    }

    @Test func cancelledReadDoesNotFallBack() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CursorTokenStore.load(stateDatabasePath: "/unused") { _ in
                Issue.record("Cancelled read reached Keychain")
                return nil
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func transientReadErrorRetainsLastGoodPolicy() async {
        let adapter = CursorProviderAdapter(
            provider: CursorUsageProvider(credentialsLoader: {
                throw CursorCredentialReadError.busy
            }))
        do {
            _ = try await adapter.fetch(now: Date())
            Issue.record("Expected a credential read failure")
        } catch let failure as UsageProviderFailure {
            #expect(failure.retainsLastGood)
            #expect(failure.message == CursorCredentialReadError.busy.errorDescription)
        } catch { Issue.record("Unexpected error type") }
    }
}

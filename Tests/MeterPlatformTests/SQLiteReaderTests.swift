import Darwin
import Foundation
import MeterTestSupport
import SQLite3
import Testing

@testable import MeterPlatform

@Suite struct SQLiteReaderTests {
    /// Creates a database like Cursor's `state.vscdb`, in WAL mode.
    private func makeDatabase(in directory: TemporaryDirectory, rows: [(String, String)]) throws
        -> URL
    {
        let url = directory.path("state.vscdb")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                handle, "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB);", nil, nil, nil)
                == SQLITE_OK)
        for (key, value) in rows {
            let sql = "INSERT INTO ItemTable VALUES ('\(key)', '\(value)');"
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        return url
    }

    @Test func readsRowsWithBindings() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let database = try makeDatabase(in: directory, rows: [("a", "1"), ("b", "2"), ("c", "3")])
        let rows = try SQLiteReader.rows(
            in: database,
            query: "SELECT key, value FROM ItemTable WHERE key IN (?, ?) ORDER BY key",
            bindings: ["a", "c"])
        #expect(rows.count == 2)
        #expect(rows[0][0] == Data("a".utf8))
        #expect(rows[1][1] == Data("3".utf8))
    }

    @Test func reportsMissingDatabases() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        #expect(throws: SQLiteReader.ReadError.notFound) {
            try SQLiteReader.rows(in: directory.path("none.vscdb"), query: "SELECT 1", bindings: [])
        }
    }

    @Test func rejectsSpecialFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fifo = directory.path("fifo.vscdb")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: SQLiteReader.ReadError.notRegularFile) {
            try SQLiteReader.rows(in: fifo, query: "SELECT 1", bindings: [])
        }
    }

    @Test func rejectsSpecialSidecars() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let database = try makeDatabase(in: directory, rows: [])
        try? FileManager.default.removeItem(atPath: database.path + "-wal")
        #expect(mkfifo(database.path + "-wal", 0o600) == 0)
        #expect(throws: SQLiteReader.ReadError.notRegularFile) {
            try SQLiteReader.rows(in: database, query: "SELECT 1", bindings: [])
        }
    }

    @Test func aLockedDatabaseIsBusyAtOnce() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // A rollback-journal database: a writer's exclusive lock blocks every reader.
        let url = directory.path("locked.db")
        var writer: OpaquePointer?
        #expect(sqlite3_open(url.path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "CREATE TABLE t (v);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(writer, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: SQLiteReader.ReadError.busy) {
            try SQLiteReader.rows(in: url, query: "SELECT v FROM t", bindings: [])
        }
        #expect(clock.now - start < .seconds(1))
        _ = sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil)
    }

    @Test func aCallerThatGaveUpInterruptsALongQuery() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let database = try makeDatabase(in: directory, rows: [("a", "1")])
        let pool = BlockingIO(label: "test")
        // Without the progress handler this query runs for minutes.
        let query = """
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10000000000)
            SELECT count(*) FROM n
            """
        await #expect(throws: TimeoutError.self) {
            try await pool.run(timeout: .milliseconds(50)) { cancellation in
                try SQLiteReader.rows(
                    in: database, query: query, bindings: [], cancellation: cancellation)
            }
        }
        #expect(await waitUntil(limit: .seconds(2)) { pool.abandonedCount == 0 })
    }

    @Test func readingCreatesNoSidecarFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // The writer closed, so the database file holds every row. Remove the sidecars, as
        // after a clean shutdown of the owner.
        let database = try makeDatabase(in: directory, rows: [("a", "1")])
        let sidecars = ["-wal", "-shm"].map { database.path + $0 }
        for sidecar in sidecars { try? FileManager.default.removeItem(atPath: sidecar) }
        // Reading can fail without a sidecar, but it must never create one.
        _ = try? SQLiteReader.rows(in: database, query: "SELECT key FROM ItemTable", bindings: [])
        #expect(sidecars.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test func neverWritesTheDatabase() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let database = try makeDatabase(in: directory, rows: [("a", "1")])
        let before = try FileManager.default.attributesOfItem(atPath: database.path)[
            .modificationDate]
        #expect(throws: SQLiteReader.ReadError.self) {
            try SQLiteReader.rows(in: database, query: "DELETE FROM ItemTable", bindings: [])
        }
        let after = try FileManager.default.attributesOfItem(atPath: database.path)[
            .modificationDate]
        #expect(before as? Date == after as? Date)
        let rows = try SQLiteReader.rows(
            in: database, query: "SELECT key FROM ItemTable", bindings: [])
        #expect(rows.count == 1)
    }
}

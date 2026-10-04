import Darwin
import Foundation
import MeterPlatform
import MeterTestSupport
import SQLite3
import Testing

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

import Foundation
import SQLite3

/// Reads rows from a live SQLite database that another app owns, without changing it.
///
/// The database opens read-only with `readonly_shm=1`, so SQLite reads committed WAL data
/// under normal locking and never creates, writes, or repairs the database or its sidecar
/// files. Immutable mode is never used, because the owner keeps writing. A database that needs
/// a missing sidecar fails cleanly. Busy or locked databases fail at once, without waiting.
/// Call through ``BlockingIO`` and pass its cancellation.
public enum SQLiteReader {
    public enum ReadError: Error, Equatable, LocalizedError, Sendable {
        case notFound
        case notRegularFile
        /// Another process holds a lock. Try again later.
        case busy
        case unreadable(code: Int32)

        // Messages never include the database path.
        public var errorDescription: String? {
            switch self {
            case .notFound: "The database does not exist."
            case .notRegularFile: "The database path is not a regular file."
            case .busy: "The database is busy."
            case .unreadable(let code): "The database could not be read (SQLite \(code))."
            }
        }
    }

    /// The largest value that a row can hold.
    public static let maxValueBytes: Int32 = 1024 * 1024

    /// Runs one query and returns every row as an array of column values. Text and blob
    /// columns return their bytes; NULL returns nil.
    public static func rows(
        in database: URL,
        query: String,
        bindings: [String],
        cancellation: BlockingIO.Cancellation? = nil
    ) throws(ReadError) -> [[Data?]] {
        try checkRegularFiles(database)

        var components = URLComponents()
        components.scheme = "file"
        components.path = database.path
        components.queryItems = [URLQueryItem(name: "readonly_shm", value: "1")]
        guard let uri = components.string else { throw .unreadable(code: SQLITE_CANTOPEN) }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let openStatus = sqlite3_open_v2(uri, &handle, flags, nil)
        defer { sqlite3_close_v2(handle) }
        guard openStatus == SQLITE_OK, let handle else { throw map(openStatus) }

        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, maxValueBytes)
        sqlite3_busy_timeout(handle, 0)
        let box = Unmanaged.passRetained(CancellationBox(cancellation)).toOpaque()
        defer { Unmanaged<CancellationBox>.fromOpaque(box).release() }
        sqlite3_progress_handler(
            handle, 1000,
            { context in
                guard let context else { return 0 }
                let box = Unmanaged<CancellationBox>.fromOpaque(context).takeUnretainedValue()
                return box.cancellation?.isCancelled == true ? 1 : 0
            }, box)

        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(handle, query, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepareStatus == SQLITE_OK, let statement else { throw map(prepareStatus) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let status = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            guard status == SQLITE_OK else { throw map(status) }
        }

        var rows: [[Data?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw map(status) }
            let columns = sqlite3_column_count(statement)
            rows.append((0..<columns).map { column(statement, $0) })
        }
        return rows
    }

    private static func column(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
                return Data()
            }
            return Data(bytes: bytes, count: count)
        default:
            guard let text = sqlite3_column_text(statement, index) else { return Data() }
            let count = Int(sqlite3_column_bytes(statement, index))
            return Data(bytes: text, count: count)
        }
    }

    /// Rejects devices and FIFOs at the database and at any sidecar that exists.
    private static func checkRegularFiles(_ database: URL) throws(ReadError) {
        guard LocalFile.isRegularFile(database) else {
            throw FileManager.default.fileExists(atPath: database.path)
                ? .notRegularFile : .notFound
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path),
                !LocalFile.isRegularFile(sidecar)
            {
                throw .notRegularFile
            }
        }
    }

    private static func map(_ status: Int32) -> ReadError {
        switch status & 0xFF {
        case SQLITE_BUSY, SQLITE_LOCKED: .busy
        default: .unreadable(code: status)
        }
    }

    private final class CancellationBox {
        let cancellation: BlockingIO.Cancellation?

        init(_ cancellation: BlockingIO.Cancellation?) {
            self.cancellation = cancellation
        }
    }
}

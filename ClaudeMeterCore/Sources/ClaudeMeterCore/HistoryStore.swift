import Foundation
import SQLite3

public final class HistoryStore: @unchecked Sendable {

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.claudemeter.history", qos: .utility)

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Init / deinit

    public init(directory: URL) throws {
        let path = directory.appendingPathComponent("history.sqlite").path
        var ptr: OpaquePointer?
        guard sqlite3_open(path, &ptr) == SQLITE_OK, let opened = ptr else {
            sqlite3_close(ptr)
            throw HistoryStoreError.openFailed
        }
        db = opened
        try setupSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public write

    public func append(_ record: HistoryRecord) throws {
        try synchronized { try insertRecord(record) }
    }

    // MARK: - Public read

    public func fetch(since date: Date? = nil, limit: Int = 5_000) throws -> [HistoryRecord] {
        try synchronized { try fetchRecords(since: date, limit: limit) }
    }

    /// Non-blocking async variant for use from MainActor contexts.
    public func fetchAsync(since date: Date? = nil, limit: Int = 5_000) async throws -> [HistoryRecord] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.fetchRecords(since: date, limit: limit) })
            }
        }
    }

    public func pruneOlderThan(_ date: Date) throws {
        try synchronized { try pruneRecords(before: date) }
    }

    // MARK: - Export

    public func exportCSV(since date: Date? = nil) throws -> String {
        let records = try fetch(since: date)
        var lines = ["created_at,session_percent,week_percent,session_resets_at,week_resets_at,severity,model"]
        for r in records {
            lines.append([
                Self.iso.string(from: r.createdAt),
                r.sessionPercent.map { String(format: "%.2f", $0) } ?? "",
                r.weekPercent.map { String(format: "%.2f", $0) } ?? "",
                r.sessionResetsAt.map { Self.iso.string(from: $0) } ?? "",
                r.weekResetsAt.map { Self.iso.string(from: $0) } ?? "",
                r.severity,
                (r.model ?? "").replacingOccurrences(of: ",", with: ";"),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    public func exportJSON(since date: Date? = nil) throws -> String {
        let records = try fetch(since: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - Schema setup (called from init, not on queue)

    private func setupSchema() throws {
        let ddl: [String] = [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            """
            CREATE TABLE IF NOT EXISTS history (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at        TEXT    NOT NULL,
                session_pct       REAL,
                week_pct          REAL,
                session_resets_at TEXT,
                week_resets_at    TEXT,
                severity          TEXT    NOT NULL,
                model             TEXT
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_hist_ca ON history (created_at)",
        ]
        for sql in ddl {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw HistoryStoreError.execFailed(sql)
            }
        }
        try pruneRecords(before: Date().addingTimeInterval(-30 * 86400))
    }

    // MARK: - Private operations (must run on queue or from init)

    private func insertRecord(_ record: HistoryRecord) throws {
        let sql = """
        INSERT INTO history
            (created_at, session_pct, week_pct, session_resets_at, week_resets_at, severity, model)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { s in
            bindText(s, 1, Self.iso.string(from: record.createdAt))
            bindDoubleOpt(s, 2, record.sessionPercent)
            bindDoubleOpt(s, 3, record.weekPercent)
            bindTextOpt(s, 4, record.sessionResetsAt.map { Self.iso.string(from: $0) })
            bindTextOpt(s, 5, record.weekResetsAt.map { Self.iso.string(from: $0) })
            bindText(s, 6, record.severity)
            bindTextOpt(s, 7, record.model)
            guard sqlite3_step(s) == SQLITE_DONE else { throw HistoryStoreError.stepFailed }
        }
    }

    private func fetchRecords(since date: Date?, limit: Int) throws -> [HistoryRecord] {
        let cutoff = date ?? Date.distantPast
        let sql = """
        SELECT id, created_at, session_pct, week_pct, session_resets_at, week_resets_at, severity, model
        FROM history
        WHERE created_at >= ?
        ORDER BY created_at ASC
        LIMIT ?
        """
        var records: [HistoryRecord] = []
        try withStatement(sql) { s in
            bindText(s, 1, Self.iso.string(from: cutoff))
            bindInt64(s, 2, Int64(limit))
            while sqlite3_step(s) == SQLITE_ROW {
                records.append(HistoryRecord(
                    id:              sqlite3_column_int64(s, 0),
                    createdAt:       colDate(s, 1) ?? Date(),
                    sessionPercent:  colDoubleOpt(s, 2),
                    weekPercent:     colDoubleOpt(s, 3),
                    sessionResetsAt: colDate(s, 4),
                    weekResetsAt:    colDate(s, 5),
                    severity:        colText(s, 6) ?? "unknown",
                    model:           colTextOpt(s, 7)
                ))
            }
        }
        return records
    }

    private func pruneRecords(before date: Date) throws {
        let sql = "DELETE FROM history WHERE created_at < ?"
        try withStatement(sql) { s in
            bindText(s, 1, Self.iso.string(from: date))
            guard sqlite3_step(s) == SQLITE_DONE else { throw HistoryStoreError.stepFailed }
        }
    }

    // MARK: - Thread safety

    private func synchronized<T>(_ work: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        queue.sync { result = Result { try work() } }
        return try result!.get()
    }

    // MARK: - Statement helpers

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else {
            throw HistoryStoreError.prepareFailed
        }
        defer { sqlite3_finalize(s) }
        try body(s)
    }

    private func bindText(_ s: OpaquePointer?, _ col: Int32, _ value: String) {
        sqlite3_bind_text(s, col, value, -1, Self.SQLITE_TRANSIENT)
    }
    private func bindTextOpt(_ s: OpaquePointer?, _ col: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(s, col); return }
        sqlite3_bind_text(s, col, value, -1, Self.SQLITE_TRANSIENT)
    }
    private func bindDoubleOpt(_ s: OpaquePointer?, _ col: Int32, _ value: Double?) {
        guard let value else { sqlite3_bind_null(s, col); return }
        sqlite3_bind_double(s, col, value)
    }
    private func bindInt64(_ s: OpaquePointer?, _ col: Int32, _ value: Int64) {
        sqlite3_bind_int64(s, col, value)
    }

    private func colText(_ s: OpaquePointer?, _ col: Int32) -> String? {
        guard let ptr = sqlite3_column_text(s, col) else { return nil }
        return String(cString: ptr)
    }
    private func colTextOpt(_ s: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(s, col) != SQLITE_NULL else { return nil }
        return colText(s, col)
    }
    private func colDoubleOpt(_ s: OpaquePointer?, _ col: Int32) -> Double? {
        guard sqlite3_column_type(s, col) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(s, col)
    }
    private func colDate(_ s: OpaquePointer?, _ col: Int32) -> Date? {
        guard let text = colTextOpt(s, col) else { return nil }
        return Self.iso.date(from: text)
    }
}

public enum HistoryStoreError: Error {
    case openFailed
    case execFailed(String)
    case prepareFailed
    case stepFailed
}

import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

/// Parses test lines such as `{"id":"a","count":3}`. A line without an ID counts by offset.
/// A line whose ID starts with `block-` holds the read until ``BlockedLines/open(_:)``.
struct CountingParser: HistoryFileParser {
    private struct Line: Decodable {
        let id: HistoryJSON.Text?
        let count: HistoryJSON.Count?
    }

    var records = TokenRecordSet()
    var isPartial = false

    init() {}

    mutating func append(_ line: Data, offset: Int64, decoder: JSONDecoder) {
        guard let value = try? decoder.decode(Line.self, from: line),
            let count = value.count?.value
        else {
            isPartial = true
            return
        }
        if let id = value.id?.value, id.hasPrefix("block-") { BlockedLines.wait(id) }
        records.insert(TokenRecord(date: .reference(), count: count), key: value.id?.value)
    }

    var recordCount: Int { records.count }
}

/// Holds file reads at test lines whose ID starts with `block-`, and test listings that call
/// ``wait(_:)``, like a read from a stuck volume. Each test uses its own IDs.
enum BlockedLines {
    private static let state = Locked<(open: Set<String>, arrived: Set<String>)>(([], []))

    /// A new ID that blocks until it is opened.
    static func make() -> String { "block-\(UUID().uuidString)" }

    static func open(_ id: String) {
        state.withLock { _ = $0.open.insert(id) }
    }

    /// Whether a read reached the line with `id`.
    static func hasArrived(_ id: String) -> Bool {
        state.value.arrived.contains(id)
    }

    /// Blocks the reading thread until `id` is open. The limit of 300 s only frees the thread
    /// of a test that failed before it opened the gate; no test waits for it.
    static func wait(_ id: String) {
        state.withLock { _ = $0.arrived.insert(id) }
        let deadline = Date().addingTimeInterval(300)
        while !state.value.open.contains(id), Date() < deadline { usleep(1_000) }
    }
}

typealias CountingScanner = HistoryScanner<CountingParser>

/// Groups the suites that scan real files. Scans use the shared history pool unless a test
/// passes its own, which every test that leaves stuck reads must do.
@Suite enum HistoryScans {}

/// The start of a range that every fixture file is newer than, whatever the host clock says.
let rangeStart = Date.reference(-.days(3_650))

/// One JSONL test line with a line feed.
func line(_ id: String, _ count: Int, padding: Int = 0) -> String {
    let pad = padding > 0 ? #","pad":""# + String(repeating: "x", count: padding) + #"""# : ""
    return #"{"id":"\#(id)","count":\#(count)\#(pad)}"# + "\n"
}

extension TemporaryDirectory {
    /// Appends text to an existing file, keeping its inode.
    func append(_ text: String, to relative: String) throws {
        let handle = try FileHandle(forWritingTo: path(relative))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Replaces the contents of an existing file in place, keeping its inode.
    func overwrite(_ text: String, at relative: String) throws {
        let handle = try FileHandle(forWritingTo: path(relative))
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Sets the modification date of a file.
    func touch(_ relative: String, at date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: path(relative).path)
    }

    /// A root that gives this whole directory, or one folder of it, to `account`.
    func root(_ account: AccountID = "default", _ relative: String? = nil) -> HistoryRoot {
        HistoryRoot(account: account, directory: relative.map(path) ?? url)
    }
}

extension HistoryScan where Parser == CountingParser {
    /// Each record once per account, as the providers count them.
    func total(_ account: AccountID = "default") -> Int64 {
        var records = TokenRecordSet()
        for file in files(of: account) { records.formUnion(file.parser.records) }
        return records.records.reduce(0) { $0 + $1.count }
    }

    /// True when the account cannot show complete history.
    func isPartial(_ account: AccountID = "default") -> Bool {
        partialAccounts.contains(account)
            || files(of: account).contains { !$0.isComplete || $0.parser.isPartial }
    }
}

extension CountingScanner {
    /// Scans until discovery and reading settle, at most `limit` times.
    func scanUntilComplete(
        _ roots: [HistoryRoot], account: AccountID = "default", limit: Int = 20
    ) async throws -> HistoryScan<CountingParser> {
        var result = try await scan(roots, since: rangeStart)
        for _ in 0..<limit where result.isPartial(account) {
            result = try await scan(roots, since: rangeStart)
        }
        return result
    }
}

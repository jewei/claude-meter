import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

/// Parses test lines such as `{"id":"a","count":3}`. A line without an ID counts by offset.
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
        records.insert(TokenRecord(date: .reference(), count: count), key: value.id?.value)
    }

    var recordCount: Int { records.count }
}

typealias CountingScanner = HistoryScanner<CountingParser>

/// Suites that scan real files run one test at a time. Every scan uses the process-wide
/// `BlockingIO` pool, and parallel scans would fill it while other suites test the pool.
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

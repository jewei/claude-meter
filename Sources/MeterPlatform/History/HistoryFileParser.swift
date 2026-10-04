import Foundation

/// Parses the lines of one append-only JSONL file and keeps only the counters that history
/// needs. It never keeps prompt or response text.
///
/// The scanner owns one value per file. It sends each complete line once, in file order, and
/// starts a new value when the file was replaced or rewritten.
public protocol HistoryFileParser: Sendable {
    init()

    /// Adds one complete line, without its line feed. `offset` is the byte offset of the line in
    /// its file; use it to identify a record that has no ID of its own.
    mutating func append(_ line: Data, offset: Int64, decoder: JSONDecoder)

    /// The number of records kept. The scanner stops reading a file at the per-file limit.
    var recordCount: Int { get }

    /// True when a line could not be counted, for example because it is not valid JSON.
    var isPartial: Bool { get }
}

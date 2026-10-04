import Foundation

/// Bounds the work of one history scan and the memory that the scanner keeps between scans.
///
/// A reached limit never makes history look complete: the affected account reads as partial.
public struct HistoryLimits: Equatable, Sendable {
    /// Bytes read from all files in one scan, including the checks of saved offsets.
    public var scanBytes: Int
    /// Bytes read from one file in one scan. A larger file continues on the next scan.
    public var fileBytes: Int
    /// The longest line that is parsed. A longer line is skipped.
    public var lineBytes: Int
    /// Files kept in the inventory. The newest files are kept.
    public var files: Int
    /// Directory entries visited in one scan. Discovery continues on the next scan.
    public var directoryEntries: Int
    /// Records kept from one file. Reading of the file stops at this limit.
    public var fileRecords: Int
    /// Records kept from all files of one provider.
    public var records: Int

    public init(
        scanBytes: Int = 64 * 1024 * 1024, fileBytes: Int = 8 * 1024 * 1024,
        lineBytes: Int = 1024 * 1024, files: Int = 2_048, directoryEntries: Int = 20_000,
        fileRecords: Int = 20_000, records: Int = 100_000
    ) {
        self.scanBytes = scanBytes
        self.fileBytes = fileBytes
        self.lineBytes = lineBytes
        self.files = files
        self.directoryEntries = directoryEntries
        self.fileRecords = fileRecords
        self.records = records
    }

    /// Bytes saved from the start of a file and before its saved offset, to detect a rewrite.
    static let sampleBytes = 256
    /// Bytes kept free in the scan budget for the head and boundary samples.
    static let reserveBytes = 512
    /// The size of one read.
    static let chunkBytes = 64 * 1024
    /// Directory entries visited in one blocking call, so cancellation is seen between calls.
    static let entriesPerCall = 1_024
    /// The time limit of one blocking call: a directory page, a root check, or one file.
    static let blockingTimeout: Duration = .seconds(5)
}

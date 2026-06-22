import Foundation

/// Atomic reader/writer for the latest `ClaudeUsageSnapshot`.
///
/// The snapshot is stored as pretty-printed JSON at `<directory>/current.json`.
/// Writes are atomic: data goes to a `.tmp` file first, then renamed over the
/// destination so readers never see a partial file.
///
/// When a WidgetKit extension is added (Phase 6), swap `directory` to the
/// App Group container and both targets share this same type unchanged.
public struct SnapshotStore: Sendable {
    public let directory: URL

    private var currentURL: URL   { directory.appending(path: "current.json") }
    private var lastErrorURL: URL { directory.appending(path: "last-error.json") }
    private var rawOutputURL: URL { directory.appending(path: "current.raw.txt") }

    // MARK: - Factory

    /// Creates a store backed by `~/Library/Application Support/ClaudeMeter/`.
    public static func applicationSupport() throws -> SnapshotStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appending(path: "ClaudeMeter")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SnapshotStore(directory: dir)
    }

    /// Creates a store backed by an arbitrary directory (useful for tests).
    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Write

    public func writeLatest(_ snapshot: ClaudeUsageSnapshot) throws {
        let data = try makeEncoder().encode(snapshot)
        try writeAtomically(data, to: currentURL)
    }

    /// Writes raw CLI output for diagnostics. No-op if `text` cannot be UTF-8 encoded.
    public func writeRawOutput(_ text: String) throws {
        guard let data = text.data(using: .utf8) else { return }
        try writeAtomically(data, to: rawOutputURL)
    }

    // MARK: - Read

    /// Returns nil when no snapshot file exists yet (first-run state).
    public func readLatest() throws -> ClaudeUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: currentURL.path) else { return nil }
        let data = try Data(contentsOf: currentURL)
        return try makeDecoder().decode(ClaudeUsageSnapshot.self, from: data)
    }

    // MARK: - Atomic write

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        // Data.write with .atomic writes to a temp sibling, then renames — one syscall.
        // On the same APFS/HFS+ volume this rename is atomic: no partial reads possible.
        try data.write(to: destination, options: [.atomic])
    }

    // MARK: - JSON codec (stateless, created per call to remain Sendable)

    private func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    private func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}

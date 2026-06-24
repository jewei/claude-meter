import Foundation

public struct LastErrorRecord: Codable, Equatable, Sendable {
    public var occurredAt: Date
    public var message: String

    public init(occurredAt: Date = Date(), message: String) {
        self.occurredAt = occurredAt
        self.message = message
    }
}

/// Atomic reader/writer for the latest `ClaudeUsageSnapshot`.
///
/// Files in `<directory>/`:
///   - `current.json`      — latest parsed snapshot (pretty-printed JSON)
///   - `last-error.json`   — most recent poll/parse failure
///
/// Writes use `Data.write(.atomic)`, which creates a temp file in the same
/// directory and renames it over the destination — atomic on APFS/HFS+.
///
/// The main app and WidgetKit extension both use the App Group container via
/// `appGroup(suiteName:)` so they read and write the same `current.json`.
public struct SnapshotStore: Sendable {
    public let directory: URL

    private var currentURL: URL   { directory.appending(path: "current.json") }
    private var lastErrorURL: URL { directory.appending(path: "last-error.json") }

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

    /// Creates a store backed by the shared App Group container.
    ///
    /// Both the main app and the WidgetKit extension call this factory so they
    /// read and write the same `current.json` file. Throws when the group
    /// container is unavailable — e.g. the app is unsigned or the entitlement
    /// is missing — in which case callers fall back to `applicationSupport()`.
    public static func appGroup(suiteName: String) throws -> SnapshotStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = container.appendingPathComponent(
            "Library/Application Support/ClaudeMeter",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SnapshotStore(directory: dir)
    }

    /// Copies `current.json` from a legacy store when the destination is empty.
    public static func migrateSnapshotIfNeeded(from legacy: SnapshotStore, to shared: SnapshotStore) throws {
        guard try shared.readLatest() == nil else { return }
        if let snapshot = try legacy.readLatest() {
            try shared.writeLatest(snapshot)
        }
    }

    /// Creates a store backed by an arbitrary directory (useful for tests).
    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Snapshot write/read

    public func writeLatest(_ snapshot: ClaudeUsageSnapshot) throws {
        let data = try makeEncoder().encode(snapshot)
        try writeAtomically(data, to: currentURL)
    }

    /// Returns nil when no snapshot file exists yet (first-run state).
    public func readLatest() throws -> ClaudeUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: currentURL.path) else { return nil }
        let data = try Data(contentsOf: currentURL)
        return try makeDecoder().decode(ClaudeUsageSnapshot.self, from: data)
    }

    // MARK: - Last error write/read

    public func writeLastError(_ record: LastErrorRecord) throws {
        let data = try makeEncoder().encode(record)
        try writeAtomically(data, to: lastErrorURL)
    }

    public func readLastError() throws -> LastErrorRecord? {
        guard FileManager.default.fileExists(atPath: lastErrorURL.path) else { return nil }
        let data = try Data(contentsOf: lastErrorURL)
        return try makeDecoder().decode(LastErrorRecord.self, from: data)
    }

    public func clearLastError() throws {
        guard FileManager.default.fileExists(atPath: lastErrorURL.path) else { return }
        try FileManager.default.removeItem(at: lastErrorURL)
    }

    // MARK: - Atomic write

    private func writeAtomically(_ data: Data, to destination: URL) throws {
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

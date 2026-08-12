import Foundation

public struct LastErrorRecord: Codable, Equatable, Sendable {
    public var occurredAt: Date
    public var message: String

    public init(occurredAt: Date = Date(), message: String) {
        self.occurredAt = occurredAt
        self.message = message
    }
}

public enum SnapshotStoreIOError: Error, LocalizedError, Equatable, Sendable {
    case timedOut(operation: String, seconds: TimeInterval)
    case disabledAfterTimeout

    public var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let seconds):
            "Snapshot \(operation) timed out after \(seconds.formatted())s"
        case .disabledAfterTimeout:
            "Snapshot I/O is disabled after an earlier timeout"
        }
    }
}

/// Serializes snapshot access and abandons a wedged filesystem call after a
/// bounded wait. The circuit breaker is per store, so an unavailable App Group
/// cannot consume a new thread on every poll or affect independent test stores.
final class BoundedSnapshotIO: @unchecked Sendable {
    static let readTimeout: TimeInterval = 2
    static let writeTimeout: TimeInterval = 10

    private let executionLock = NSLock()
    private let stateLock = NSLock()
    private var circuitBreakerTripped = false

    private enum Outcome<Value: Sendable>: @unchecked Sendable {
        case value(Value)
        case failure(any Error)
    }

    private final class ResultBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func set(_ value: Value) {
            lock.withLock { self.value = value }
        }

        func get() -> Value? {
            lock.withLock { value }
        }
    }

    func perform<Value: Sendable>(
        operation: String,
        timeout: TimeInterval,
        body: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        guard !isDisabled else { throw SnapshotStoreIOError.disabledAfterTimeout }
        executionLock.lock()
        defer { executionLock.unlock() }
        guard !isDisabled else { throw SnapshotStoreIOError.disabledAfterTimeout }

        let result = ResultBox<Outcome<Value>>()
        let completion = DispatchSemaphore(value: 0)
        let thread = Thread {
            do {
                result.set(.value(try body()))
            } catch {
                result.set(.failure(error))
            }
            completion.signal()
        }
        thread.name = "ClaudeMeter.snapshot.\(operation)"
        thread.start()

        guard completion.wait(timeout: .now() + timeout) == .success else {
            stateLock.withLock { circuitBreakerTripped = true }
            throw SnapshotStoreIOError.timedOut(operation: operation, seconds: timeout)
        }
        guard let outcome = result.get() else {
            throw CocoaError(.fileReadUnknown)
        }
        switch outcome {
        case .value(let value): return value
        case .failure(let error): throw error
        }
    }

    private var isDisabled: Bool {
        stateLock.withLock { circuitBreakerTripped }
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
/// Reads and writes run on dedicated threads with bounded waits; one timeout
/// trips a per-store circuit breaker so a wedged container cannot stall the app
/// or consume an abandoned thread on every poll.
///
/// The main app and WidgetKit extension both use the App Group container via
/// `appGroup(suiteName:)` so they read and write the same `current.json`.
public struct SnapshotStore: Sendable {
    public let directory: URL
    private let boundedIO: BoundedSnapshotIO

    private var currentURL: URL { directory.appending(path: "current.json") }
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
        return try applicationSupport(in: base)
    }

    /// Injectable application-support factory for hermetic tests and alternate hosts.
    public static func applicationSupport(
        in base: URL, fileManager: FileManager = .default
    ) throws -> SnapshotStore {
        let dir = base.appending(path: "ClaudeMeter")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return SnapshotStore(directory: dir)
    }

    /// Creates a store backed by the shared App Group container.
    ///
    /// Both the main app and the WidgetKit extension call this factory so they
    /// read and write the same `current.json` file. Throws when the group
    /// container is unavailable — e.g. the app is unsigned or the entitlement
    /// is missing — in which case callers fall back to `applicationSupport()`.
    public static func appGroup(suiteName: String) throws -> SnapshotStore {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName
            )
        else {
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
    public static func migrateSnapshotIfNeeded(from legacy: SnapshotStore, to shared: SnapshotStore)
        throws
    {
        guard try shared.readLatest() == nil else { return }
        if let snapshot = try legacy.readLatest() {
            try shared.writeLatest(snapshot)
        }
    }

    /// Creates a store backed by an arbitrary directory (useful for tests).
    public init(directory: URL) {
        self.directory = directory
        self.boundedIO = BoundedSnapshotIO()
    }

    // MARK: - Snapshot write/read

    public func writeLatest(_ snapshot: ClaudeUsageSnapshot) throws {
        let data = try makeEncoder().encode(snapshot)
        try writeAtomically(data, to: currentURL)
    }

    /// Returns nil when no snapshot file exists yet (first-run state).
    public func readLatest() throws -> ClaudeUsageSnapshot? {
        do {
            let url = currentURL
            let data = try boundedIO.perform(
                operation: "read", timeout: BoundedSnapshotIO.readTimeout
            ) {
                try Data(contentsOf: url)
            }
            return try makeDecoder().decode(ClaudeUsageSnapshot.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    // MARK: - Last error write/read

    public func writeLastError(_ record: LastErrorRecord) throws {
        var sanitized = record
        sanitized.message = DiagnosticsSanitizer.sanitize(record.message)
        let data = try makeEncoder().encode(sanitized)
        try writeAtomically(data, to: lastErrorURL)
    }

    public func readLastError() throws -> LastErrorRecord? {
        do {
            let url = lastErrorURL
            let data = try boundedIO.perform(
                operation: "read", timeout: BoundedSnapshotIO.readTimeout
            ) {
                try Data(contentsOf: url)
            }
            return try makeDecoder().decode(LastErrorRecord.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func clearLastError() throws {
        do {
            let url = lastErrorURL
            try boundedIO.perform(operation: "delete", timeout: BoundedSnapshotIO.writeTimeout) {
                try FileManager.default.removeItem(at: url)
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    // MARK: - Atomic write

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        try boundedIO.perform(operation: "write", timeout: BoundedSnapshotIO.writeTimeout) {
            try data.write(to: destination, options: [.atomic])
        }
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

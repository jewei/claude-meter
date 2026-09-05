import Darwin
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
    case invalidStoredFile
    case storedFileTooLarge(maximumByteCount: Int)
    case storedFileChanged
    case storedFileReadFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let seconds):
            "Snapshot \(operation) timed out after \(seconds.formatted())s"
        case .disabledAfterTimeout:
            "Snapshot I/O is disabled after an earlier timeout"
        case .invalidStoredFile:
            "Snapshot data is not a regular file"
        case .storedFileTooLarge(let maximumByteCount):
            "Snapshot data exceeds the \(maximumByteCount)-byte limit"
        case .storedFileChanged:
            "Snapshot data changed while it was read"
        case .storedFileReadFailed:
            "Snapshot data could not be read"
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

/// Retains one I/O gate for each App Group suite in this process. The factory
/// itself touches the App Group filesystem before a `SnapshotStore` exists, so
/// it must use the same bounded path as later reads and writes. Retention also
/// makes a factory or read timeout fail later attempts fast instead of leaking
/// one blocked thread each time WidgetKit asks for a new store value.
private final class AppGroupSnapshotIORegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: BoundedSnapshotIO] = [:]

    func gate(for suiteName: String) -> BoundedSnapshotIO {
        lock.withLock {
            if let gate = gates[suiteName] { return gate }
            let gate = BoundedSnapshotIO()
            gates[suiteName] = gate
            return gate
        }
    }
}

/// `FileManager` is safe for concurrent use but is not declared `Sendable` on
/// every supported Foundation version. This wrapper lets a bounded worker keep
/// an injected manager without weakening the worker's `@Sendable` closure.
private struct SnapshotFileManager: @unchecked Sendable {
    let value: FileManager
}

/// Atomic reader/writer for the latest `ClaudeUsageSnapshot`.
///
/// Files in `<directory>/`:
///   - `current.json`      — latest parsed Claude snapshot (pretty-printed JSON)
///   - `main-meter.json`   — selected provider's normalized widget reading
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
    static let maximumReadBytes = 4 * 1_024 * 1_024
    private static let appGroupIORegistry = AppGroupSnapshotIORegistry()
    private static let applicationSupportIO = BoundedSnapshotIO()

    public let directory: URL
    private let boundedIO: BoundedSnapshotIO

    private var currentURL: URL { directory.appending(path: "current.json") }
    private var mainMeterURL: URL { directory.appending(path: "main-meter.json") }
    private var lastErrorURL: URL { directory.appending(path: "last-error.json") }

    // MARK: - Factory

    /// Creates a store backed by `~/Library/Application Support/ClaudeMeter/`.
    public static func applicationSupport() throws -> SnapshotStore {
        let fileManager = SnapshotFileManager(value: FileManager.default)
        let boundedIO = applicationSupportIO
        let base = try boundedIO.perform(
            operation: "prepare-application-support",
            timeout: BoundedSnapshotIO.writeTimeout
        ) {
            try fileManager.value.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        return try applicationSupport(
            in: base, fileManager: fileManager.value, boundedIO: boundedIO)
    }

    /// Injectable application-support factory for hermetic tests and alternate hosts.
    public static func applicationSupport(
        in base: URL, fileManager: FileManager = .default
    ) throws -> SnapshotStore {
        try applicationSupport(in: base, fileManager: fileManager, boundedIO: BoundedSnapshotIO())
    }

    private static func applicationSupport(
        in base: URL, fileManager: FileManager, boundedIO: BoundedSnapshotIO
    ) throws -> SnapshotStore {
        let fileManager = SnapshotFileManager(value: fileManager)
        let dir = base.appending(path: "ClaudeMeter")
        try boundedIO.perform(
            operation: "prepare-application-support",
            timeout: BoundedSnapshotIO.writeTimeout
        ) {
            try fileManager.value.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return SnapshotStore(directory: dir, boundedIO: boundedIO)
    }

    /// Creates a store backed by the shared App Group container.
    ///
    /// Both the main app and the WidgetKit extension call this factory so they
    /// read and write the same `current.json` file. Throws when the group
    /// container is unavailable — e.g. the app is unsigned or the entitlement
    /// is missing — in which case callers fall back to `applicationSupport()`.
    public static func appGroup(suiteName: String) throws -> SnapshotStore {
        let fileManager = SnapshotFileManager(value: FileManager.default)
        let boundedIO = appGroupIORegistry.gate(for: suiteName)
        let dir = try boundedIO.perform(
            operation: "prepare-app-group",
            timeout: BoundedSnapshotIO.writeTimeout
        ) {
            guard
                let container = fileManager.value.containerURL(
                    forSecurityApplicationGroupIdentifier: suiteName
                )
            else {
                throw CocoaError(.fileNoSuchFile)
            }
            let dir = container.appendingPathComponent(
                "Library/Application Support/ClaudeMeter",
                isDirectory: true
            )
            try fileManager.value.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return SnapshotStore(directory: dir, boundedIO: boundedIO)
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
        self.init(directory: directory, boundedIO: BoundedSnapshotIO())
    }

    private init(directory: URL, boundedIO: BoundedSnapshotIO) {
        self.directory = directory
        self.boundedIO = boundedIO
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
                try Self.readBoundedData(at: url)
            }
            return try makeDecoder().decode(ClaudeUsageSnapshot.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    // MARK: - Main meter write/read

    public func writeMainMeter(_ reading: MainMeterReading) throws {
        let data = try makeEncoder().encode(reading)
        try writeAtomically(data, to: mainMeterURL)
    }

    public func readMainMeter() throws -> MainMeterReading? {
        do {
            let url = mainMeterURL
            let data = try boundedIO.perform(
                operation: "read-main-meter", timeout: BoundedSnapshotIO.readTimeout
            ) {
                try Self.readBoundedData(at: url)
            }
            let reading = try makeDecoder().decode(MainMeterReading.self, from: data)
            return reading.schemaVersion == 1 ? reading : nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func clearMainMeter() throws {
        do {
            let url = mainMeterURL
            try boundedIO.perform(
                operation: "delete-main-meter", timeout: BoundedSnapshotIO.writeTimeout
            ) {
                try FileManager.default.removeItem(at: url)
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
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
                try Self.readBoundedData(at: url)
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

    /// Reads one app-owned file through a nonblocking, no-follow descriptor. The
    /// explicit cap prevents a corrupt durable file from allocating without bound
    /// in a worker that can outlive the caller's timeout.
    private static func readBoundedData(at url: URL) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                throw CocoaError(.fileReadNoSuchFile)
            }
            throw SnapshotStoreIOError.storedFileReadFailed(code: code)
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else {
            throw SnapshotStoreIOError.storedFileReadFailed(code: errno)
        }
        guard (before.st_mode & S_IFMT) == S_IFREG, before.st_size >= 0 else {
            throw SnapshotStoreIOError.invalidStoredFile
        }
        guard before.st_size <= off_t(maximumReadBytes) else {
            throw SnapshotStoreIOError.storedFileTooLarge(
                maximumByteCount: maximumReadBytes)
        }

        let expectedByteCount = Int(before.st_size)
        var data = Data(count: expectedByteCount)
        let actualByteCount = try data.withUnsafeMutableBytes { buffer -> Int in
            guard expectedByteCount > 0, let baseAddress = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < expectedByteCount {
                let count = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedByteCount - offset,
                    off_t(offset))
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    throw SnapshotStoreIOError.storedFileReadFailed(code: errno)
                }
            }
            return offset
        }
        guard actualByteCount == expectedByteCount else {
            throw SnapshotStoreIOError.storedFileChanged
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else {
            throw SnapshotStoreIOError.storedFileReadFailed(code: errno)
        }
        guard before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else { throw SnapshotStoreIOError.storedFileChanged }
        return data
    }

    // MARK: - JSON codec (stateless, created per call to remain Sendable)

    private func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            guard PersistedDateBounds.contains(date) else {
                throw EncodingError.invalidValue(
                    date,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Date is outside the supported persistence interval"))
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    private func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}

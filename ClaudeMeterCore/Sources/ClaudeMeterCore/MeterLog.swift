import Foundation
import os

/// The app's logging seam.
///
/// Redaction happens here, not at the call sites. Every message and every metadata
/// value passes through `DiagnosticsSanitizer` before it reaches `os.Logger` or the
/// optional file sink, so no call site can leak an email address, a home path, a
/// token, or a session key by forgetting to sanitize first.
///
/// `Diagnostics` shows the present state only. This seam records what happened
/// before a fault, which is what an intermittent bug report needs.
public enum MeterLog {
    /// One subsystem per area of the app, so `log stream` and the log file can be
    /// filtered without a text search.
    public enum Category: String, CaseIterable, Sendable {
        case app
        case poll
        case bridge
        case oauth
        case cost
        case notification
        case widget
    }

    public enum Level: String, Sendable {
        case debug
        case info
        case warning
        case error

        var osLogType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .warning: .default
            case .error: .error
            }
        }
    }

    public static let subsystem = "com.jewei.claudemeter"

    /// Returns the logger for one category. Cheap enough to call per use.
    public static func logger(_ category: Category) -> MeterLogger {
        MeterLogger(category: category)
    }

    // MARK: - File sink

    /// The optional log file. It stays absent until the user turns the sink on.
    public static var fileURL: URL { MeterLogFileSink.shared.fileURL }

    public static var isFileLoggingEnabled: Bool { MeterLogFileSink.shared.isEnabled }

    /// Turns the file sink on or off. Turning it off deletes the file, because a
    /// user who withdraws consent should not leave the record behind.
    public static func setFileLoggingEnabled(_ enabled: Bool) {
        // Record the transition into the sink that is about to close, then open or
        // delete. Logging after the change would be dropped by the disabled guard.
        if !enabled { logger(.app).info("File logging disabled") }
        MeterLogFileSink.shared.setEnabled(enabled)
        if enabled { logger(.app).info("File logging enabled") }
    }
}

/// One category's logger. Values reach `os.Logger` and the file sink only after
/// sanitization.
public struct MeterLogger: Sendable {
    private let category: MeterLog.Category
    /// Receives text that is already sanitized. Tests replace it to prove that the
    /// seam, and not the call site, performs the redaction.
    private let emit: @Sendable (MeterLog.Level, MeterLog.Category, String) -> Void

    init(category: MeterLog.Category) {
        let osLogger = os.Logger(
            subsystem: MeterLog.subsystem, category: category.rawValue)
        self.init(category: category) { level, category, safe in
            osLogger.log(level: level.osLogType, "\(safe, privacy: .public)")
            MeterLogFileSink.shared.append(level: level, category: category, message: safe)
        }
    }

    init(
        category: MeterLog.Category,
        emit: @escaping @Sendable (MeterLog.Level, MeterLog.Category, String) -> Void
    ) {
        self.category = category
        self.emit = emit
    }

    public func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    public func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    public func warning(_ message: @autoclosure () -> String) {
        log(.warning, message())
    }

    public func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    /// Logs a failure with its typed reason. The reason is sanitized like any other
    /// text, so a provider error that embeds a token cannot escape.
    public func error(_ message: @autoclosure () -> String, error underlying: any Error) {
        let reason =
            (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
        log(.error, "\(message()): \(reason)")
    }

    public func log(_ level: MeterLog.Level, _ message: String) {
        // The one redaction point. Everything below this line is already safe.
        emit(level, category, DiagnosticsSanitizer.sanitize(message))
    }
}

/// Appends sanitized lines to an optional log file.
///
/// Off by default. The file is capped and rotated once, so an enabled sink cannot
/// grow without limit. Writes run on a utility queue, so a slow disk never blocks a
/// poll or the main actor.
final class MeterLogFileSink: @unchecked Sendable {
    static let shared = MeterLogFileSink()

    /// Keep this small. The sink exists to explain the last few hours, not to keep
    /// history.
    private static let maximumByteCount: UInt64 = 4 * 1024 * 1024

    private let queue = DispatchQueue(
        label: "com.jewei.claudemeter.logfile", qos: .utility)
    private let lock = NSLock()
    private var enabledFlag = false
    private var handle: FileHandle?
    private let directoryURL: URL
    let fileURL: URL
    private let previousFileURL: URL

    init(directoryURL: URL? = nil) {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeMeterLogs", isDirectory: true)
        let base = directoryURL ?? library ?? fallback
        self.directoryURL = base
        self.fileURL = base.appendingPathComponent("ClaudeMeter.log")
        self.previousFileURL = base.appendingPathComponent("ClaudeMeter.previous.log")
    }

    var isEnabled: Bool { lock.withLock { enabledFlag } }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { enabledFlag = enabled }
        queue.async { [self] in
            if enabled {
                openIfNeeded()
            } else {
                closeHandle()
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: previousFileURL)
            }
        }
    }

    func append(level: MeterLog.Level, category: MeterLog.Category, message: String) {
        guard isEnabled else { return }
        // Stamp the call time here, but format it on the queue: the shared
        // formatter is not `Sendable`, so only the queue may touch it.
        let occurredAt = Date()
        queue.async { [self] in
            let line = Self.line(
                level: level, category: category, message: message, occurredAt: occurredAt)
            guard let data = line.data(using: .utf8) else { return }
            guard let handle = openIfNeeded() else { return }
            try? handle.write(contentsOf: data)
            rotateIfNeeded(handle)
        }
    }

    /// Formats one line. Call only from `queue`: it reads the shared formatter.
    static func line(
        level: MeterLog.Level, category: MeterLog.Category, message: String,
        occurredAt: Date = Date()
    ) -> String {
        let timestamp = ISO8601DateFormatter.logFormatter.string(from: occurredAt)
        let flattened = message.replacingOccurrences(of: "\n", with: " ")
        return "\(timestamp) [\(level.rawValue)] \(category.rawValue): \(flattened)\n"
    }

    @discardableResult
    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: fileURL.path) {
            // An earlier build, or a user's editor, can leave the file readable by
            // others. SPECS promises `0600`, so repair it before reopening.
            if let mode = (try? fm.attributesOfItem(atPath: fileURL.path))?[.posixPermissions]
                as? NSNumber, mode.uint16Value & 0o077 != 0
            {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        } else {
            fm.createFile(
                atPath: fileURL.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? opened.seekToEnd()
        handle = opened
        return opened
    }

    private func rotateIfNeeded(_ handle: FileHandle) {
        guard let offset = try? handle.offset(), offset >= Self.maximumByteCount else {
            return
        }
        closeHandle()
        let fm = FileManager.default
        try? fm.removeItem(at: previousFileURL)
        try? fm.moveItem(at: fileURL, to: previousFileURL)
        openIfNeeded()
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// Waits for queued writes. Tests need it because appends are asynchronous.
    /// Call only from outside `queue`; `queue.sync` from the queue would deadlock.
    func drainForTesting() {
        queue.sync {}
    }
}

extension ISO8601DateFormatter {
    /// Formatters are not `Sendable`, but this one is immutable after creation and
    /// is used only by the log sink's serial queue.
    fileprivate nonisolated(unsafe) static let logFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

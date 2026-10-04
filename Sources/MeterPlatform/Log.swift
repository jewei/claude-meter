import Foundation
import MeterDomain
import os

/// The only way to log. Every message is redacted before it reaches the unified log or the
/// optional log file, so a call site cannot leak a secret. Pass raw text.
///
/// Log faults, policy decisions, and state changes, not routine successes.
public struct Log: Sendable {
    public enum Category: String, Sendable {
        case app, refresh, claude, codex, cursor, grok, history
    }

    public static let subsystem = "com.jewei.claudemeter"

    private let category: Category
    private let logger: Logger

    public init(_ category: Category) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
    }

    public func info(_ message: String) { write(message, level: .info) }
    public func notice(_ message: String) { write(message, level: .notice) }
    public func warning(_ message: String) { write(message, level: .warning) }
    public func error(_ message: String) { write(message, level: .error) }

    /// Logs `message` with the description of `error`.
    public func error(_ message: String, _ error: any Error) {
        write("\(message): \(error.localizedDescription)", level: .error)
    }

    private enum Level: String {
        case info, notice, warning, error
    }

    private func write(_ message: String, level: Level) {
        let text = Redactor.redact(message)
        switch level {
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        LogFile.shared.append(
            "\(Date().formatted(.iso8601)) [\(level.rawValue)] \(category.rawValue): \(text)")
    }
}

/// An optional copy of the log in `~/Library/Logs/ClaudeMeter/ClaudeMeter.log`
/// (`ClaudeMeter Debug` for a development build).
///
/// Off by default. The directory is private to the user (0700) and the file is 0600. At 4 MiB
/// the file rotates once to `ClaudeMeter.previous.log`. Turning it off deletes both files.
public final class LogFile: Sendable {
    public static let shared = LogFile(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/\(AppIdentity.folderName)", directoryHint: .isDirectory))

    public let directory: URL
    public let rotationBytes: UInt64
    public var current: URL { directory.appending(path: "ClaudeMeter.log") }
    public var previous: URL { directory.appending(path: "ClaudeMeter.previous.log") }

    private struct State: Sendable {
        var isEnabled = false
        var handle: FileHandle?
    }

    // Read and written only on `queue`.
    private nonisolated(unsafe) var state = State()
    private let queue = DispatchQueue(label: "com.jewei.claudemeter.log-file", qos: .utility)

    public init(directory: URL, rotationBytes: UInt64 = 4 * 1024 * 1024) {
        self.directory = directory
        self.rotationBytes = rotationBytes
    }

    public var isEnabled: Bool {
        queue.sync { state.isEnabled }
    }

    public func setEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard enabled != state.isEnabled else { return }
            state.isEnabled = enabled
            if enabled {
                state.handle = openFile()
            } else {
                try? state.handle?.close()
                state.handle = nil
                try? FileManager.default.removeItem(at: current)
                try? FileManager.default.removeItem(at: previous)
            }
        }
    }

    func append(_ line: String) {
        queue.async { [self] in
            guard state.isEnabled, let handle = state.handle else { return }
            let flat = line.replacingOccurrences(of: "\n", with: " ") + "\n"
            try? handle.write(contentsOf: Data(flat.utf8))
            if let size = try? handle.offset(), size >= rotationBytes {
                rotate()
            }
        }
    }

    /// Waits until every queued write has finished. For tests.
    func flush() {
        queue.sync {}
    }

    private func rotate() {
        try? state.handle?.close()
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
        state.handle = openFile()
    }

    private func openFile() -> FileHandle? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if !manager.fileExists(atPath: current.path) {
                manager.createFile(
                    atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
            let handle = try FileHandle(forWritingTo: current)
            try handle.seekToEnd()
            return handle
        } catch {
            return nil
        }
    }
}

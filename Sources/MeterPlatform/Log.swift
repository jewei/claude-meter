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
    private let file: LogFile

    /// Logs to the unified log and to `file`, which writes only while it is enabled. Tests
    /// pass their own file.
    public init(_ category: Category, file: LogFile = .shared) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
        self.file = file
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
        file.append(
            "\(Date().formatted(.iso8601)) [\(level.rawValue)] \(category.rawValue): \(text)")
    }
}

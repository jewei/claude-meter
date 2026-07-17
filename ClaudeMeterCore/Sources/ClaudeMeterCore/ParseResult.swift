import Foundation

/// One bounded, non-sensitive step in the Claude source fallback chain.
public struct SourceAttempt: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case statusline
        case oauth
        case cache
    }

    public enum Outcome: String, Equatable, Sendable {
        case selected
        case skipped
        case failed
    }

    public enum Reason: String, Equatable, Sendable {
        case freshData
        case sourceDisabled
        case notConnected
        case staleData
        case noData
        case cooldown
        case rateLimited
        case credentialsMissing
        case credentialsUnavailable
        case credentialsInvalid
        case refreshDeferred
        case refreshRejected
        case refreshFailed
        case unauthorized
        case networkError
        case invalidResponse
        case requestFailed
        case cachedSnapshot
        case cacheMissing
    }

    public let source: Source
    public let outcome: Outcome
    public let reason: Reason

    public init(source: Source, outcome: Outcome, reason: Reason) {
        self.source = source
        self.outcome = outcome
        self.reason = reason
    }

    public var diagnosticDescription: String {
        "\(source.rawValue): \(outcome.rawValue) (\(reason.rawValue))"
    }
}

public struct ParseResult: Sendable {
    public let snapshot: ClaudeUsageSnapshot?
    public let warnings: [ParseWarning]
    public let errors: [ParseError]
    public let rawHash: String
    public let parserVersion: String
    public let sourceAttempts: [SourceAttempt]

    public var hasUsableSnapshot: Bool { snapshot != nil }
    public var isFatal: Bool { !errors.isEmpty }

    init(
        snapshot: ClaudeUsageSnapshot?,
        warnings: [ParseWarning],
        errors: [ParseError],
        rawHash: String,
        parserVersion: String = "unknown",
        sourceAttempts: [SourceAttempt] = []
    ) {
        self.snapshot = snapshot
        self.warnings = warnings
        self.errors = errors
        self.rawHash = rawHash
        self.parserVersion = parserVersion
        self.sourceAttempts = sourceAttempts
    }

    func prependingSourceAttempt(_ attempt: SourceAttempt) -> ParseResult {
        ParseResult(
            snapshot: snapshot,
            warnings: warnings,
            errors: errors,
            rawHash: rawHash,
            parserVersion: parserVersion,
            sourceAttempts: [attempt] + sourceAttempts
        )
    }
}

public struct ParseWarning: Equatable, Sendable, CustomStringConvertible {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }

    public var description: String { "[\(field)] \(message)" }
}

public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

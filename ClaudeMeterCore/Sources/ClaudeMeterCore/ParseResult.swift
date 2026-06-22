import Foundation

public struct ParseResult: Sendable {
    public let snapshot: ClaudeUsageSnapshot?
    public let warnings: [ParseWarning]
    public let errors: [ParseError]
    public let rawHash: String
    public let parserVersion: String

    public var hasUsableSnapshot: Bool { snapshot != nil }
    public var isFatal: Bool { !errors.isEmpty }

    init(
        snapshot: ClaudeUsageSnapshot?,
        warnings: [ParseWarning],
        errors: [ParseError],
        rawHash: String,
        parserVersion: String = ClaudeOutputParser.parserVersion
    ) {
        self.snapshot = snapshot
        self.warnings = warnings
        self.errors = errors
        self.rawHash = rawHash
        self.parserVersion = parserVersion
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

import Foundation

/// The draft in the manual token form: pasted tokens and an optional expiry.
///
/// Pasted text loses the spaces and line breaks around it. Connect needs an access token and
/// no check that is still running. Escape cancels the form only while both token fields are
/// empty, so a stray key never loses pasted tokens.
public struct ManualTokenDraft: Equatable, Sendable {
    /// What Connect sends.
    public struct Submission: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date?
    }

    /// How far ahead the expiry picker starts: a typical access token lifetime.
    static let defaultLifetime: TimeInterval = 8 * 3_600

    public var accessToken = ""
    public var refreshToken = ""
    public var hasExpiry = false
    public var expiry: Date

    /// An empty draft whose expiry picker starts eight hours after `now`.
    public init(now: Date) {
        expiry = now.addingTimeInterval(Self.defaultLifetime)
    }

    /// Escape cancels the form only while both token fields are empty, apart from spaces and
    /// line breaks.
    public var escapeCancels: Bool {
        Self.cleaned(accessToken) == nil && Self.cleaned(refreshToken) == nil
    }

    /// Whether Connect is enabled: there is an access token, and no check runs.
    public func canConnect(isWorking: Bool) -> Bool {
        submission != nil && !isWorking
    }

    /// The cleaned tokens and the expiry when it is set, or nil without an access token.
    public var submission: Submission? {
        guard let access = Self.cleaned(accessToken) else { return nil }
        return Submission(
            accessToken: access, refreshToken: Self.cleaned(refreshToken),
            expiresAt: hasExpiry ? expiry : nil)
    }

    /// The pasted text without surrounding spaces or line breaks, or nil when empty.
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

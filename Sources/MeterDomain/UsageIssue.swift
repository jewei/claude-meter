import Foundation

/// A problem to show beside a reading. The message is always redacted.
public struct UsageIssue: Codable, Hashable, Sendable {
    public let message: String
    /// When the provider allows the next request, for example after HTTP 429.
    /// The UI counts down to it.
    public let retryAt: Date?
    /// The user must act, for example sign in again. Otherwise the app recovers by itself.
    public let needsAction: Bool

    public init(_ message: String, retryAt: Date? = nil, needsAction: Bool = false) {
        self.message = Redactor.redact(message)
        self.retryAt = DateBounds.validated(retryAt)
        self.needsAction = needsAction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try container.decode(String.self, forKey: .message),
            retryAt: try container.decodeIfPresent(Date.self, forKey: .retryAt),
            needsAction: try container.decode(Bool.self, forKey: .needsAction))
    }
}

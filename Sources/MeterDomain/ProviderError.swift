import Foundation

/// A refresh that produced no new reading.
///
/// Providers throw this for every expected failure. ``keepsLastReading`` decides whether the
/// app keeps showing the previous reading as stale. Keep it only while the reading still belongs
/// to the signed-in owner (see ``AccountOwner``).
public struct ProviderError: Error, LocalizedError, Sendable {
    public let issue: UsageIssue
    public let keepsLastReading: Bool

    public init(_ issue: UsageIssue, keepsLastReading: Bool = true) {
        self.issue = issue
        self.keepsLastReading = keepsLastReading
    }

    public init(
        _ message: String, retryAt: Date? = nil, needsAction: Bool = false,
        keepsLastReading: Bool = true
    ) {
        self.init(
            UsageIssue(message, retryAt: retryAt, needsAction: needsAction),
            keepsLastReading: keepsLastReading)
    }

    /// Wraps an unexpected error as a temporary failure.
    public init(wrapping error: any Error) {
        if let error = error as? ProviderError {
            self = error
        } else {
            self.init(error.localizedDescription)
        }
    }

    public var errorDescription: String? { issue.message }
}

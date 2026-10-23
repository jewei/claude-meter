import Foundation
import MeterDomain

/// One notification that the evaluator owes (``AlertEvaluator``).
public struct Alert: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case lowEnergy
        case runOut
        case refill
    }

    /// One limit window of one account. Alert state lives per key.
    public struct Key: Hashable, Sendable {
        public let provider: ProviderID
        public let account: AccountID
        public let window: String
    }

    public let key: Key
    public let kind: Kind
    public let title: String
    public let body: String

    /// One notification per key and kind: a new one replaces the old one of the same window
    /// and kind, and a run-out alert does not replace a low-energy alert.
    public var notificationID: String {
        "\(key.provider.rawValue)|\(key.account.rawValue)|\(key.window)|\(kind.rawValue)"
    }
}

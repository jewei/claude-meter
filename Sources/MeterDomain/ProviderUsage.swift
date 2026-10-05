import Foundation

/// Everything one provider reported in one refresh.
public struct ProviderUsage: Codable, Hashable, Sendable {
    public let provider: ProviderID
    /// Every configured account, in provider order, including unavailable ones.
    public var accounts: [AccountUsage]

    public init(provider: ProviderID, accounts: [AccountUsage]) {
        self.provider = provider
        self.accounts = accounts
    }

    /// The newest account observation.
    public var observedAt: Date? {
        accounts.compactMap(\.observedAt).max()
    }

    public var hasObservation: Bool {
        accounts.contains(where: \.hasObservation)
    }

    public func account(_ id: AccountID) -> AccountUsage? {
        accounts.first { $0.id == id }
    }
}

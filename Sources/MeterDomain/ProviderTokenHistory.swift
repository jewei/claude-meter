import Foundation

/// Token history for every account of one provider.
public struct ProviderTokenHistory: Hashable, Sendable {
    public enum Source: Sendable {
        /// Local session records on this Mac, counted per account folder.
        case thisMac
        /// Usage that the provider reports for the account.
        case account
    }

    public let provider: ProviderID
    public let source: Source
    public let accounts: [AccountID: TokenHistory]
    public let observedAt: Date
    public let timeZoneID: String
    public let coverageStart: Date
    /// The login whose usage this is. Set it for an `.account` source; local history belongs
    /// to its folders, not to a login, and ignores it.
    public let owner: AccountOwner?

    public init(
        provider: ProviderID, source: Source, accounts: [AccountID: TokenHistory],
        coverageStart: Date, observedAt: Date, timeZoneID: String, owner: AccountOwner? = nil
    ) {
        self.provider = provider
        self.source = source
        self.accounts = accounts
        self.coverageStart = coverageStart
        self.observedAt = observedAt
        self.timeZoneID = timeZoneID
        self.owner = owner
    }

    /// Whether this history may still be shown for the current login. Local history always
    /// belongs. An account history follows ``OwnerStatus/admits(_:)``, the rule of
    /// ``AccountUsage/belongs(to:)``, so one without an owner belongs to no login.
    public func belongs(to status: OwnerStatus) -> Bool {
        switch source {
        case .thisMac: true
        case .account: status.admits(owner)
        }
    }

    /// The history for one card. An account without records reads as unknown, never zero.
    public func history(for account: AccountID) -> TokenHistory {
        accounts[account]
            ?? .empty(coverageStart: coverageStart, observedAt: observedAt, timeZoneID: timeZoneID)
    }
}

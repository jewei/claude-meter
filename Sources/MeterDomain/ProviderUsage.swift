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

/// The lifecycle of one provider's value: fresh, kept after a failure, or missing.
public enum Reading<Value: Hashable & Sendable>: Hashable, Sendable {
    /// The last refresh succeeded.
    case current(Value, observedAt: Date)
    /// The last refresh failed, and the previous value still applies.
    case stale(Value, observedAt: Date, issue: UsageIssue)
    /// No usable value. `partial` can hold unavailable accounts with their own issues.
    case failed(UsageIssue, partial: Value? = nil)

    public var value: Value? {
        switch self {
        case .current(let value, _), .stale(let value, _, _): value
        case .failed(_, let partial): partial
        }
    }

    public var issue: UsageIssue? {
        switch self {
        case .current: nil
        case .stale(_, _, let issue), .failed(let issue, _): issue
        }
    }

    /// The time of the last successful observation.
    public var observedAt: Date? {
        switch self {
        case .current(_, let date), .stale(_, let date, _): date
        case .failed: nil
        }
    }

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    /// Whether a refresh is due. Failed and stale readings always are. A current reading is
    /// due at `maxAge`, or at once when its date is in the future (the clock moved back).
    public func needsRefresh(at now: Date, maxAge: TimeInterval) -> Bool {
        guard case .current(_, let observedAt) = self else { return true }
        let age = now.timeIntervalSince(observedAt)
        return !age.isFinite || age < 0 || age >= maxAge
    }
}

import Foundation

/// The latest quota facts for one account.
public struct AccountUsage: Codable, Hashable, Sendable, Identifiable {
    public let id: AccountID
    /// The provider's label. The app replaces it with the user's display name, if set.
    public var name: String
    /// The plan that the login reports, such as "Max 20x" or "Plus".
    public var plan: String?
    public var windows: [QuotaWindow]
    public var balances: [Balance]
    /// Nil when the provider reports no reset allowance for this account.
    public var resetAllowance: ResetAllowance?
    /// When the provider observed this usage. Nil means no usable observation.
    public var observedAt: Date?
    /// The source says this observation is old, for example after a failed refresh.
    /// Consumers also treat an old `observedAt` as stale.
    public var isStale: Bool
    public var issue: UsageIssue?
    /// Who the observation belongs to. Nil when the provider cannot tell.
    public var owner: AccountOwner?
    /// Another configured account uses the same login.
    public var sharesLogin: Bool

    public init(
        id: AccountID,
        name: String,
        plan: String? = nil,
        windows: [QuotaWindow] = [],
        balances: [Balance] = [],
        resetAllowance: ResetAllowance? = nil,
        observedAt: Date?,
        isStale: Bool = false,
        issue: UsageIssue? = nil,
        owner: AccountOwner? = nil,
        sharesLogin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.plan = plan
        self.windows = windows
        self.balances = balances
        self.resetAllowance = resetAllowance
        self.observedAt = DateBounds.validated(observedAt)
        self.isStale = isStale
        self.issue = issue
        self.owner = owner
        self.sharesLogin = sharesLogin
    }

    /// A configured account with no usable observation.
    public static func unavailable(
        id: AccountID, name: String, issue: UsageIssue, owner: AccountOwner? = nil
    ) -> AccountUsage {
        AccountUsage(id: id, name: name, observedAt: nil, issue: issue, owner: owner)
    }

    public var hasObservation: Bool { observedAt != nil }

    /// This observation, kept after a failed refresh. Expired windows become unknown.
    public func retained(issue: UsageIssue, now: Date) -> AccountUsage {
        var copy = resolved(at: now, isStale: true)
        copy.issue = issue
        return copy
    }

    /// Windows resolved at `now`. See ``QuotaWindow/resolved(at:isStale:)``.
    public func resolved(at now: Date, isStale stale: Bool) -> AccountUsage {
        var copy = self
        copy.isStale = isStale || stale
        copy.windows = windows.map { $0.resolved(at: now, isStale: copy.isStale) }
        return copy
    }

    /// The most constrained binding window of `kind`. On equal usage the later reset wins,
    /// because that limit blocks work for longer. An unknown reset counts as the latest.
    public func bindingWindow(_ kind: QuotaWindow.Kind) -> QuotaWindow? {
        windows.filter { $0.kind == kind && $0.isBinding }.max { lhs, rhs in
            if lhs.pressure != rhs.pressure { return lhs.pressure < rhs.pressure }
            guard let lhsReset = lhs.resetsAt else { return false }
            guard let rhsReset = rhs.resetsAt else { return true }
            return lhsReset < rhsReset
        }
    }

    /// The highest severity across binding windows.
    public func severity(_ thresholds: Thresholds) -> Severity {
        windows.filter(\.isBinding).map { $0.severity(thresholds) }.max() ?? .unknown
    }

    /// Selection rank: the highest pressure of any binding window, -1 when all are unknown.
    public var pressure: Double {
        windows.filter(\.isBinding).map(\.pressure).max() ?? -1
    }

    public func balance(_ kind: Balance.Kind) -> Balance? {
        balances.first { $0.kind == kind }
    }
}

/// Proof that a reading belongs to the login that is signed in now.
///
/// Providers compute an owner from local credentials. A reading survives a failed refresh only
/// while its owner still matches. Both cases hold a SHA-256 hex digest, never the raw value.
public enum AccountOwner: Codable, Hashable, Sendable {
    /// Derived from stable account identifiers, such as user and organization IDs.
    /// Survives token renewal and can be stored on disk.
    case identity(String)
    /// Derived from the credential itself because no identity is known. Changes on token
    /// renewal and never leaves memory.
    case credential(String)

    public var isPersistable: Bool {
        if case .identity = self { return true }
        return false
    }
}

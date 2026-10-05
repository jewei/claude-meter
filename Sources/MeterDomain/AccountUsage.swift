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
    /// When the provider observed this usage. Nil means no usable observation. A date outside
    /// ``DateBounds`` becomes nil.
    public var observedAt: Date? {
        didSet { observedAt = DateBounds.validated(observedAt) }
    }
    /// The source says this observation is old, for example after a failed refresh.
    /// Consumers also treat an old `observedAt` as stale.
    public var isStale: Bool
    public var issue: UsageIssue?
    /// When the provider last tried to refresh this account, successful or not. A date outside
    /// ``DateBounds`` becomes nil.
    public var attemptedAt: Date? {
        didSet { attemptedAt = DateBounds.validated(attemptedAt) }
    }
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
        attemptedAt: Date? = nil,
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
        self.attemptedAt = DateBounds.validated(attemptedAt)
        self.owner = owner
        self.sharesLogin = sharesLogin
    }

    /// Decodes through the initializer above, so dates from disk are validated like dates
    /// from providers.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(AccountID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            plan: try container.decodeIfPresent(String.self, forKey: .plan),
            windows: try container.decode([QuotaWindow].self, forKey: .windows),
            balances: try container.decode([Balance].self, forKey: .balances),
            resetAllowance: try container.decodeIfPresent(
                ResetAllowance.self, forKey: .resetAllowance),
            observedAt: try container.decodeIfPresent(Date.self, forKey: .observedAt),
            isStale: try container.decode(Bool.self, forKey: .isStale),
            issue: try container.decodeIfPresent(UsageIssue.self, forKey: .issue),
            attemptedAt: try container.decodeIfPresent(Date.self, forKey: .attemptedAt),
            owner: try container.decodeIfPresent(AccountOwner.self, forKey: .owner),
            sharesLogin: try container.decode(Bool.self, forKey: .sharesLogin))
    }

    /// A configured account with no usable observation.
    public static func unavailable(
        id: AccountID, name: String, issue: UsageIssue, attemptedAt: Date? = nil,
        owner: AccountOwner? = nil
    ) -> AccountUsage {
        AccountUsage(
            id: id, name: name, observedAt: nil, issue: issue, attemptedAt: attemptedAt,
            owner: owner)
    }

    public var hasObservation: Bool { observedAt != nil }

    /// This observation, kept after a failed refresh at `now`. Expired windows become unknown.
    public func retained(issue: UsageIssue, now: Date) -> AccountUsage {
        var copy = resolved(at: now, isStale: true)
        copy.issue = issue
        copy.attemptedAt = now
        return copy
    }

    /// Windows resolved at `now`. See ``QuotaWindow/resolved(at:isStale:)``.
    ///
    /// When a billing window has reset, the balances of that period
    /// (``Balance/Kind/isPeriodSpend``) are dropped: they counted a period that ended. Other
    /// balances, such as prepaid money or credits, stay. Resolution is idempotent.
    public func resolved(at now: Date, isStale stale: Bool) -> AccountUsage {
        var copy = self
        copy.isStale = isStale || stale
        copy.windows = windows.map { $0.resolved(at: now, isStale: copy.isStale) }
        let periodEnded = windows.contains { window in
            guard window.kind == .billing, let resetsAt = window.resetsAt else { return false }
            return resetsAt <= now
        }
        if periodEnded { copy.balances.removeAll { $0.kind.isPeriodSpend } }
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

extension AccountUsage {
    /// Whether this observation may still be shown for the current login.
    ///
    /// The single retention rule for every provider: an observation survives failures while
    /// its owner is still signed in. A temporary read failure proves nothing, so it keeps the
    /// observation. An account without an observation has nothing to protect.
    public func belongs(to status: OwnerStatus) -> Bool {
        guard hasObservation else { return true }
        return status.admits(owner)
    }
}

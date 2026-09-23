import Foundation

public enum ProviderID: String, CaseIterable, Codable, Sendable {
    case claude, codex, cursor, grok
}

/// Quota observations and sanitized account failures. Authentication stays provider-local.
public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public var accounts: [ProviderAccountSnapshot]
    /// Latest included quota observation, not the time this projection was built.
    /// Each account retains its own observation time. For an unavailable-only
    /// result this is the request time; ReadingState has no successful poll time.
    public let fetchedAt: Date

    public init(provider: ProviderID, accounts: [ProviderAccountSnapshot], fetchedAt: Date) {
        self.provider = provider
        self.accounts = accounts
        self.fetchedAt = fetchedAt
    }
}

public struct ProviderAccountSnapshot: Codable, Equatable, Sendable, Identifiable {
    /// Stable within this provider. This is a selection key, not authentication proof.
    public let id: String
    public var label: String
    public var plan: String?
    /// Optional public identity text. Never used as the account key.
    public let subtitle: String?
    public let windows: [UsageWindow]
    public var balances: [BalanceItem]
    /// Nil means this configured account has no usable observation.
    public let observedAt: Date?
    /// Explicit source staleness. Consumers must also check observation age.
    public var isStale: Bool
    public var lastError: String?
    public var lastAttemptAt: Date?

    public init(
        id: String, label: String, plan: String? = nil, subtitle: String? = nil,
        windows: [UsageWindow], balances: [BalanceItem] = [], observedAt: Date?,
        isStale: Bool = false, lastError: String? = nil, lastAttemptAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.plan = plan
        self.subtitle = subtitle
        self.windows = windows
        self.balances = balances
        self.observedAt = observedAt
        self.isStale = isStale
        self.lastError = lastError.map(DiagnosticsSanitizer.sanitize)
        self.lastAttemptAt = lastAttemptAt
    }

    public func resolvedWindows(asOf now: Date) -> [UsageWindow] {
        windows.map { $0.resolved(asOf: now, isStale: isStale) }
    }
}

/// Session/weekly roles support the existing menu-bar window choices. Scoped and
/// billing windows remain ordinary entries; titles do not drive policy.
public enum UsageWindowKind: String, Codable, Sendable {
    case session, weekly, scoped, billing, other
}

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: UsageWindowKind
    public let usedPercent: Double?
    /// Only a provider-reported reset/end time. Never a prediction.
    public let resetAt: Date?
    /// Some scoped/budget rows are display-only and cannot select the main account.
    public let contributesToQuota: Bool
    /// Retains the existing over-limit severity without storing percentages above 100.
    public let isOverLimit: Bool

    /// Provider adapters construct windows here so normalization has one rule.
    public init(
        id: String, title: String, kind: UsageWindowKind,
        usedPercent: Double?, resetAt: Date?, contributesToQuota: Bool = true,
        isOverLimit: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        let finite = usedPercent.flatMap { $0.isFinite ? $0 : nil }
        self.usedPercent = finite.map { min(100, max(0, $0)) }
        self.resetAt = resetAt.flatMap { PersistedDateBounds.contains($0) ? $0 : nil }
        self.contributesToQuota = contributesToQuota
        self.isOverLimit = finite != nil && (isOverLimit || (finite ?? 0) > 100)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, usedPercent, resetAt, contributesToQuota, isOverLimit
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            kind: try values.decode(UsageWindowKind.self, forKey: .kind),
            usedPercent: try values.decodeIfPresent(Double.self, forKey: .usedPercent),
            resetAt: try values.decodeIfPresent(Date.self, forKey: .resetAt),
            contributesToQuota: try values.decode(Bool.self, forKey: .contributesToQuota),
            isOverLimit: try values.decode(Bool.self, forKey: .isOverLimit))
    }

    public func resolved(asOf now: Date, isStale: Bool = false) -> UsageWindow {
        let window = LimitWindow(percentUsed: usedPercent, resetsAt: resetAt)
            .resolved(asOf: now, isStale: isStale)
        return UsageWindow(
            id: id, title: title, kind: kind,
            usedPercent: window.percentUsed, resetAt: window.resetsAt,
            contributesToQuota: contributesToQuota,
            isOverLimit: isOverLimit && window.resetsAt == resetAt)
    }

    public func displayPercent(showUsage: Bool) -> Double? {
        usedPercent.map { showUsage ? $0 : 100 - $0 }
    }

    public func severity(thresholds: UsageThresholds = .default) -> UsageSeverity {
        isOverLimit ? .overLimit : thresholds.severity(for: usedPercent)
    }
}

/// Money, credits, or counted allowances. `value` is in `unit`, never minor units.
/// `limit` is optional: credits do not imply a currency or a spending cap.
public struct BalanceItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let value: Decimal?
    public let limit: Decimal?
    public let unit: String?
    /// Non-numeric provider state, such as "Unlimited" or "Paused".
    public let displayText: String?
    /// Optional allowance details. Their sum need not equal the authoritative total.
    public let details: [BalanceDetail]?

    public init(
        id: String, title: String, value: Decimal?, limit: Decimal? = nil,
        unit: String? = nil, displayText: String? = nil, details: [BalanceDetail]? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.limit = limit
        self.unit = unit
        self.displayText = displayText
        self.details = details
    }
}

public struct BalanceDetail: Codable, Equatable, Sendable {
    public let title: String
    /// Allowance expiry, distinct from a quota window's reset time.
    public let expiresAt: Date?

    public init(title: String, expiresAt: Date?) {
        self.title = title
        self.expiresAt = expiresAt
    }
}

/// Selection policy remains outside the provider snapshot. Ties keep input order.
public enum ProviderAccountSelection {
    public static func primary(
        from accounts: [ProviderAccountSnapshot], pinnedAccountID: String?, asOf now: Date
    ) -> ProviderAccountSnapshot? {
        if let pinnedAccountID {
            return accounts.first { $0.id == pinnedAccountID && $0.observedAt != nil }
        }
        var selected: ProviderAccountSnapshot?
        var highest = -Double.infinity
        for account in accounts where account.observedAt != nil {
            let usage =
                account.resolvedWindows(asOf: now)
                .filter(\.contributesToQuota)
                .compactMap { $0.isOverLimit ? 101 : $0.usedPercent }.max() ?? -1
            if usage > highest {
                selected = account
                highest = usage
            }
        }
        return selected
    }
}

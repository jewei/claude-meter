import Foundation

/// Money or credits that the provider reports beside its limits.
public struct Balance: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Claude pay-as-you-go spend beyond the plan, with its monthly limit.
        case extraUsage
        /// Codex credits.
        case credits
        /// Cursor spend in the current billing period, with its limit.
        case spend
        /// Grok on-demand spend, with its cap.
        case onDemand
        /// Grok prepaid balance.
        case prepaid
    }

    public enum Unit: Codable, Hashable, Sendable {
        /// An ISO 4217 code, such as "USD".
        case currency(String)
        case credits
    }

    public var id: Kind { kind }
    public let kind: Kind
    /// The amount in `unit`, never in minor units such as cents.
    public let amount: Decimal?
    public let limit: Decimal?
    public let unit: Unit
    /// Billing for this balance is paused, for example when extra usage ran out of credit.
    public let isPaused: Bool
    /// The provider reports no cap, for example unlimited Codex credits.
    public let isUnlimited: Bool

    public init(
        kind: Kind, amount: Decimal?, limit: Decimal? = nil, unit: Unit,
        isPaused: Bool = false, isUnlimited: Bool = false
    ) {
        self.kind = kind
        self.amount = amount
        self.limit = limit
        self.unit = unit
        self.isPaused = isPaused
        self.isUnlimited = isUnlimited
    }
}

/// Resets of a usage limit that the provider grants, such as Claude usage-limit resets and
/// Codex reset credits. The app only displays them and never uses one.
public struct ResetAllowance: Codable, Hashable, Sendable {
    public struct Reset: Codable, Hashable, Sendable {
        public let title: String
        /// When the reset expires. This is not a quota window reset time.
        public let expiresAt: Date?

        public init(title: String, expiresAt: Date?) {
            self.title = title
            self.expiresAt = DateBounds.validated(expiresAt)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                title: try container.decode(String.self, forKey: .title),
                expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt))
        }
    }

    /// The authoritative number of resets available.
    public let available: Int
    /// Details for some or all available resets, sorted by expiry with unknown expiry last.
    /// Fewer details than `available` means the provider omitted some.
    public let resets: [Reset]

    public init(available: Int, resets: [Reset] = []) {
        self.available = max(0, available)
        self.resets = Array(
            resets.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
                .prefix(self.available))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            available: try container.decode(Int.self, forKey: .available),
            resets: try container.decode([Reset].self, forKey: .resets))
    }
}

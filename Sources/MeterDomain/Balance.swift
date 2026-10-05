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

        /// Spend that counts one billing period and starts again in the next: Cursor spend and
        /// Grok on-demand spend. It belongs to the account's billing window.
        public var isPeriodSpend: Bool {
            self == .spend || self == .onDemand
        }
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

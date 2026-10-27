import Foundation

/// What the tokens of a period would cost at API list prices. Not a bill: subscriptions pay
/// a flat fee.
public struct CostEstimate: Hashable, Sendable {
    /// US dollars, above zero.
    public let amount: Decimal
    /// False when some tokens of the period have no price, or the history is partial. The
    /// real amount is then higher.
    public let isComplete: Bool

    public init(amount: Decimal, isComplete: Bool) {
        self.amount = amount
        self.isComplete = isComplete
    }
}

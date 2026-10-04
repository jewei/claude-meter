import Foundation

/// The card-order line in Settings > Appearance, and whether "Use automatic order" applies.
public struct CardOrderHint: Equatable, Sendable {
    public let text: String
    /// A saved order or a pinned account exists, so the user can go back to automatic order.
    public let canReset: Bool

    public init(_ settings: Settings) {
        canReset = !settings.cards.order.isEmpty || !settings.menuBar.pinnedAccounts.isEmpty
        text =
            canReset
            ? "Your order is saved. Drag cards in the popover to change it."
            : "Drag cards in the popover to change their order."
    }
}

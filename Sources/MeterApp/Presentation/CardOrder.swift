import MeterDomain

/// The user's card order and the drag-to-top rule that selects the main meter.
public enum CardOrder {
    /// Saved cards keep their saved order, new cards follow in automatic order, and the main
    /// card always comes first. Without a main card, the first Claude or Codex card comes
    /// first, so a saved order never puts Cursor, Grok, or extra usage on top while a card
    /// that can own the menu bar shows (`docs/product.md` §2.7). Saved IDs of hidden cards
    /// are kept for their return.
    public static func ordered(automatic: [CardID], saved: [CardID], main: CardID?) -> [CardID] {
        let visible = Set(automatic)
        var seen = Set<CardID>()
        var result = saved.filter { visible.contains($0) && seen.insert($0).inserted }
        result += automatic.filter { seen.insert($0).inserted }
        let lead =
            main.flatMap { result.firstIndex(of: $0) }
            ?? result.firstIndex { $0.menuBarSelection != nil }
        if let lead {
            result.insert(result.remove(at: lead), at: 0)
        }
        return result
    }

    /// The outcome of a move: the order to save, and the account that becomes the main meter
    /// when the moved card was dropped first.
    public struct Move: Equatable, Sendable {
        public let order: [CardID]
        public let newMain: CardID?
    }

    public enum MoveResult: Equatable, Sendable {
        case moved(Move)
        /// The card is already there, and is the main card or not first.
        case unchanged
        /// The move would put a card first that cannot own the menu bar (Cursor, Grok, extra
        /// usage) while a card that can is visible, or would take the main card off the top.
        case refused
    }

    /// Moves `card` to `index` within the visible order.
    ///
    /// Only the moved card can become the main meter: a Claude or Codex card dropped first
    /// that is not the main card yet. That includes a drop in place of a first card that is
    /// not the main card, which happens when the main provider has no card: otherwise that
    /// card could never become the main meter. A move lower in the list never changes the
    /// main meter or a pin, so a missing pinned account stays missing (`docs/product.md`
    /// §2.5). The main card stays first; another card replaces it only by a drop on top.
    public static func move(
        _ card: CardID, to index: Int, visible: [CardID], saved: [CardID], main: CardID?
    ) -> MoveResult {
        guard let from = visible.firstIndex(of: card), visible.indices.contains(index) else {
            return .unchanged
        }
        let becomesMain = index == 0 && card.menuBarSelection != nil && card != main
        if index == from, !becomesMain { return .unchanged }
        if card == main { return .refused }
        var order = visible
        order.insert(order.remove(at: from), at: index)
        guard let first = order.first else { return .unchanged }
        let anyEligible = visible.contains { $0.menuBarSelection != nil }
        if first.menuBarSelection == nil, anyEligible { return .refused }
        let hidden = saved.filter { !visible.contains($0) }
        return .moved(Move(order: order + hidden, newMain: becomesMain ? card : nil))
    }
}

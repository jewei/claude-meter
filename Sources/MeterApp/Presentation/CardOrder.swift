import MeterDomain

/// The user's card order and the drag-to-top rule that selects the main meter.
public enum CardOrder {
    /// Saved cards keep their saved order, new cards follow in automatic order, and the main
    /// card always comes first. Saved IDs of hidden cards are kept for their return.
    public static func ordered(automatic: [CardID], saved: [CardID], main: CardID?) -> [CardID] {
        let visible = Set(automatic)
        var seen = Set<CardID>()
        var result = saved.filter { visible.contains($0) && seen.insert($0).inserted }
        result += automatic.filter { seen.insert($0).inserted }
        if let main, let index = result.firstIndex(of: main) {
            result.insert(result.remove(at: index), at: 0)
        }
        return result
    }

    /// The outcome of a move: the order to save, and the account that becomes the main meter
    /// when the move put a different card first.
    public struct Move: Equatable, Sendable {
        public let order: [CardID]
        public let newMain: CardID?
    }

    public enum MoveResult: Equatable, Sendable {
        case moved(Move)
        /// The card is already there, and is the main card or not first.
        case unchanged
        /// The move would put a card first that cannot own the menu bar (Cursor, Grok, extra
        /// usage) while a card that can is visible.
        case refused
    }

    /// Moves `card` to `index` within the visible order.
    ///
    /// A Claude or Codex card that ends up first becomes the main meter. That includes a drop
    /// in place of a first card that is not the main card yet, which happens when the main
    /// provider has no card: otherwise that card could never become the main meter.
    public static func move(
        _ card: CardID, to index: Int, visible: [CardID], saved: [CardID], main: CardID?
    ) -> MoveResult {
        guard let from = visible.firstIndex(of: card), visible.indices.contains(index) else {
            return .unchanged
        }
        if index == from, index != 0 || card == main || card.menuBarSelection == nil {
            return .unchanged
        }
        var order = visible
        order.insert(order.remove(at: from), at: index)
        guard let first = order.first else { return .unchanged }
        let anyEligible = visible.contains { $0.menuBarSelection != nil }
        if first.menuBarSelection == nil, anyEligible { return .refused }
        let newMain = first.menuBarSelection != nil && first != main ? first : nil
        let hidden = saved.filter { !visible.contains($0) }
        return .moved(Move(order: order + hidden, newMain: newMain))
    }
}

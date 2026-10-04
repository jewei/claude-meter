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

    /// Moves `card` to `index` within the visible order. Returns nil when nothing changes, or
    /// when the move would put a card first that cannot own the menu bar (Cursor, Grok, extra
    /// usage).
    public static func move(
        _ card: CardID, to index: Int, visible: [CardID], saved: [CardID], main: CardID?
    ) -> Move? {
        guard let from = visible.firstIndex(of: card), index != from,
            visible.indices.contains(index)
        else { return nil }
        var order = visible
        order.insert(order.remove(at: from), at: index)
        guard let first = order.first, first.menuBarSelection != nil else { return nil }
        let hidden = saved.filter { !visible.contains($0) }
        return Move(order: order + hidden, newMain: first == main ? nil : first)
    }
}

import CoreGraphics

/// Where a dragged card goes. Pure, so the rule has tests.
///
/// A card moves only after the pointer crosses the midpoint of a neighbor. Once the list
/// rearranges, the pointer sits on the moved card again, so it does not swing back while the
/// pointer stays still, even when the cards have different heights.
enum CardReorder {
    /// The index that `card` moves to, or nil when it stays.
    ///
    /// - Parameters:
    ///   - card: the dragged card.
    ///   - location: the pointer, in the coordinate space of `frames`.
    ///   - order: the visible cards, top to bottom.
    ///   - frames: each card's frame. A card without a frame cannot be a target.
    static func targetIndex<ID: Hashable>(
        moving card: ID, to location: CGPoint, in order: [ID], frames: [ID: CGRect]
    ) -> Int? {
        guard let source = order.firstIndex(of: card), let sourceFrame = frames[card],
            location.x >= sourceFrame.minX, location.x <= sourceFrame.maxX,
            let top = order.first.flatMap({ frames[$0] }),
            let bottom = order.last.flatMap({ frames[$0] }),
            location.y >= top.minY, location.y <= bottom.maxY
        else { return nil }
        // Upward: the highest card above the source whose midpoint is below the pointer.
        if let above = order[..<source].firstIndex(where: { id in
            frames[id].map { location.y < $0.midY } ?? false
        }) {
            return above
        }
        // Downward: the lowest card below the source whose midpoint is above the pointer.
        return order.indices.dropFirst(source + 1).last { index in
            frames[order[index]].map { location.y > $0.midY } ?? false
        }
    }
}

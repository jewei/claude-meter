import MeterDomain

/// A card drag before the drop, as the popover shows it.
///
/// The list shows the new order while the card moves, but the settings change once, on the
/// drop (`AppModel.moveCard`). So a card that passes over the top and comes back does not
/// become the main meter on the way (`docs/product.md` §2.7). A preview takes only a place
/// that the drop accepts, so a drop is never refused.
public struct CardDragPreview: Equatable, Sendable {
    /// The dragged card.
    public let card: CardID
    /// Where the card lands on the drop, as an index in the order before the drag.
    public let index: Int
    /// The visible cards in the order that the list shows during the drag.
    public let order: [CardID]
    /// The card with the Menu bar pill during the drag: the dragged card when the drop makes
    /// it the main meter, else the main card.
    public let menuBarCard: CardID?
}

extension AccountsModel {
    /// The preview of `card` dropped at `index` of the current order, or nil when the drop
    /// would be refused (``CardOrder/move(_:to:visible:saved:main:)``) or `index` is not a
    /// place in the list. During a drag, ``dragPreview(moving:to:after:)`` then keeps the last
    /// preview.
    public func dragPreview(moving card: CardID, to index: Int) -> CardDragPreview? {
        let ids = cards.map(\.id)
        guard ids.contains(card), ids.indices.contains(index) else { return nil }
        let main = cards.first(where: \.isMain)?.id
        switch CardOrder.move(card, to: index, visible: ids, saved: [], main: main) {
        case .refused:
            return nil
        case .unchanged:
            return CardDragPreview(card: card, index: index, order: ids, menuBarCard: main)
        case .moved(let move):
            return CardDragPreview(
                card: card, index: index, order: move.order, menuBarCard: move.newMain ?? main)
        }
    }

    /// The preview as the pointer moves `card`. `target` is the place that the pointer
    /// reached, or nil while it has not left the card's place. A place that the drop accepts
    /// gives a new preview, else `last` stays.
    ///
    /// The drag starts in the card's own place. There a first card that is not the main card
    /// becomes the main meter, so it shows the pill at once and a drop in place pins it
    /// (`docs/product.md` §2.7). A pointer that stays in the first place reaches no target,
    /// so only this start lets such a drag make the card the main meter.
    public func dragPreview(
        moving card: CardID, to target: Int?, after last: CardDragPreview?
    ) -> CardDragPreview? {
        if let target, let preview = dragPreview(moving: card, to: target) { return preview }
        if let last, last.card == card { return last }
        guard let own = cards.firstIndex(where: { $0.id == card }) else { return nil }
        return dragPreview(moving: card, to: own)
    }

    /// Whether `preview` still fits the cards. It does not after a refresh changed them during
    /// the drag; then the list shows the cards in their own order and the drop does nothing.
    public func accepts(_ preview: CardDragPreview) -> Bool {
        dragPreview(moving: preview.card, to: preview.index) == preview
    }

    /// The cards in the order that the list shows: the preview's while it fits, else their own.
    public func cards(during preview: CardDragPreview?) -> [CardModel] {
        guard let preview, accepts(preview) else { return cards }
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return preview.order.compactMap { byID[$0] }
    }

    /// Whether `card` shows the Menu bar pill: the main card, or during a drag the card that
    /// the drop makes the main meter.
    public func showsMenuBarPill(_ card: CardID, during preview: CardDragPreview?) -> Bool {
        if let preview, accepts(preview) { return preview.menuBarCard == card }
        return cards.contains { $0.id == card && $0.isMain }
    }
}

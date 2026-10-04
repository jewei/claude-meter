import MeterApp
import SwiftUI

/// The account cards in the user's order, with drag to reorder.
///
/// The drag is local: no pasteboard, no drop from outside. A card moves when the pointer
/// crosses a neighbor's midpoint (``CardReorder``), and the model refuses a move that would
/// put a card first that cannot own the menu bar. The gesture state resets when the drag ends
/// or is cancelled, and a hidden popover does not reorder. VoiceOver users move cards with
/// the "Move up" and "Move down" actions.
struct CardList: View {
    nonisolated private static let space = "cards"

    let accounts: AccountsModel
    let model: AppModel

    @Environment(\.popoverIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: CardDrag?
    @State private var frames: [CardID: CGRect] = [:]

    var body: some View {
        let ids = accounts.cards.map(\.id)
        VStack(spacing: 10) {
            AccountsHeader(showsLegend: accounts.showsRingLegend, dragHint: accounts.dragHint)
            ForEach(Array(accounts.cards.enumerated()), id: \.element.id) { index, card in
                VStack(alignment: .leading, spacing: 6) {
                    if card.isMain { MenuBarPill() }
                    CardView(card: card, model: model)
                }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.space))
                } action: { frame in
                    frames[card.id] = frame
                }
                .simultaneousGesture(dragGesture(for: card.id), including: isVisible ? .all : .none)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(card.title)
                .accessibilityAction(named: "Move up") { move(card.id, to: index - 1, in: ids) }
                .accessibilityAction(named: "Move down") { move(card.id, to: index + 1, in: ids) }
            }
        }
        .coordinateSpace(.named(Self.space))
        .onChange(of: drag) { _, drag in
            guard let drag,
                let target = CardReorder.targetIndex(
                    moving: drag.card, to: drag.location, in: ids, frames: frames)
            else { return }
            move(drag.card, to: target, in: ids)
        }
    }

    private func dragGesture(for card: CardID) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
            .updating($drag) { value, state, _ in
                state = CardDrag(card: card, location: value.location)
            }
    }

    private func move(_ card: CardID, to index: Int, in ids: [CardID]) {
        guard isVisible, ids.indices.contains(index) else { return }
        withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) {
            _ = model.moveCard(card, to: index, visible: ids)
        }
    }
}

/// A drag in progress. It lives only in gesture state, so it ends with the gesture.
private struct CardDrag: Equatable {
    let card: CardID
    let location: CGPoint
}

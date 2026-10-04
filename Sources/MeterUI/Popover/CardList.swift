import MeterApp
import SwiftUI

/// The account cards in the user's order, with drag to reorder.
///
/// The drag is local: no pasteboard, no drop from outside. A card moves when the pointer
/// crosses a neighbor's midpoint (``CardReorder``), and the model refuses a move that would
/// put a card first that cannot own the menu bar. The dragged card lifts, the gesture state
/// resets when the drag ends or is cancelled, and a hidden popover does not reorder. A drag
/// never also opens or closes a bar card.
///
/// Dragging is not the only way: "Use in Menu Bar" in a Claude or Codex card's context menu
/// and VoiceOver actions move cards too. VoiceOver offers "Move up" and "Move down" only
/// where the move works, and announces where the card went.
struct CardList: View {
    nonisolated private static let space = "cards"

    let accounts: AccountsModel
    let model: AppModel

    @Environment(\.popoverIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: CardDrag?
    @State private var frames: [CardID: CGRect] = [:]
    /// True from the first drag movement until just after the mouse goes up, so the release
    /// does not toggle the bar card under the pointer.
    @State private var isReordering = false

    var body: some View {
        let ids = accounts.cards.map(\.id)
        VStack(spacing: 10) {
            AccountsHeader(showsLegend: accounts.showsRingLegend, dragHint: accounts.dragHint)
            ForEach(Array(accounts.cards.enumerated()), id: \.element.id) { index, card in
                let isDragged = drag?.card == card.id
                VStack(alignment: .leading, spacing: 6) {
                    if card.isMain { MenuBarPill() }
                    CardView(card: card, model: model)
                }
                .scaleEffect(isDragged && !reduceMotion ? 1.02 : 1)
                .shadow(color: .black.opacity(isDragged ? 0.12 : 0), radius: 8, y: 4)
                .zIndex(isDragged ? 1 : 0)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.space))
                } action: { frame in
                    frames[card.id] = frame
                }
                .simultaneousGesture(dragGesture(for: card.id), including: isVisible ? .all : .none)
                .contextMenu {
                    if card.canUseInMenuBar {
                        Button("Use in Menu Bar") { move(card, to: 0, in: ids) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(card.spokenTitle)
                .accessibilityActions {
                    if card.canUseInMenuBar {
                        Button("Use in Menu Bar") { move(card, to: 0, in: ids) }
                    }
                    if accounts.canMove(card.id, by: -1) {
                        Button("Move up") { move(card, to: index - 1, in: ids) }
                    }
                    if accounts.canMove(card.id, by: 1) {
                        Button("Move down") { move(card, to: index + 1, in: ids) }
                    }
                }
            }
        }
        .environment(\.isReorderingCards, isReordering)
        .coordinateSpace(.named(Self.space))
        .onChange(of: drag) { _, drag in
            guard let drag else {
                endReordering()
                return
            }
            if !isReordering { isReordering = true }
            guard
                let target = CardReorder.targetIndex(
                    moving: drag.card, to: drag.location, in: ids, frames: frames),
                let card = accounts.cards.first(where: { $0.id == drag.card })
            else { return }
            move(card, to: target, in: ids, announces: false)
        }
    }

    private func dragGesture(for card: CardID) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
            .updating($drag) { value, state, _ in
                state = CardDrag(card: card, location: value.location)
            }
    }

    /// The mouse-up that ends a drag also reaches the card's header button. Clear the flag
    /// after that click has been handled.
    private func endReordering() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            isReordering = false
        }
    }

    private func move(_ card: CardModel, to index: Int, in ids: [CardID], announces: Bool = true) {
        guard isVisible, ids.indices.contains(index) else { return }
        let moved = withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) {
            model.moveCard(card.id, to: index, visible: ids)
        }
        guard moved, announces else { return }
        AccessibilityNotification.Announcement(accounts.moveAnnouncement(card, to: index)).post()
    }
}

/// A drag in progress. It lives only in gesture state, so it ends with the gesture.
private struct CardDrag: Equatable {
    let card: CardID
    let location: CGPoint
}

extension EnvironmentValues {
    /// A card drag is moving cards, so a bar card header must not toggle on the release.
    @Entry var isReorderingCards = false
}

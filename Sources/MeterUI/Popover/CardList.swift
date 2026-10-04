import MeterApp
import SwiftUI

/// The account cards in the user's order, with drag to reorder.
///
/// The drag is local: no pasteboard, no drop from outside. While the card moves, the list
/// shows a preview from view state only (``CardDragPreview``): the card takes a new place when
/// the pointer crosses a neighbor's midpoint (``CardReorder``), never a place that the drop
/// would refuse, and the Menu bar pill goes to the card that the drop makes the main meter.
/// The settings change once, on the drop (`AppModel.moveCard`), so a card that passes over the
/// top and comes back changes nothing. The dragged card lifts, a cancelled drag puts the cards
/// back, and a hidden popover does not reorder. A drag never also opens or closes a bar card.
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
    /// The order that a drop would give. Only the drop changes the settings.
    @State private var preview: CardDragPreview?
    @State private var frames: [CardID: CGRect] = [:]
    /// True from the first drag movement until just after the mouse goes up, so the release
    /// does not toggle the bar card under the pointer.
    @State private var isReordering = false

    var body: some View {
        let ids = accounts.cards.map(\.id)
        let shown = accounts.cards(during: preview)
        VStack(spacing: 10) {
            AccountsHeader(legend: accounts.ringLegend, dragHint: accounts.dragHint)
            ForEach(shown) { card in
                let isDragged = drag?.card == card.id
                let index = ids.firstIndex(of: card.id) ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    if accounts.showsMenuBarPill(card.id, during: preview) { MenuBarPill() }
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
                        Button("Use in Menu Bar") { move(card.id, to: 0) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(card.spokenTitle)
                .accessibilityActions {
                    if card.canUseInMenuBar {
                        Button("Use in Menu Bar") { move(card.id, to: 0) }
                    }
                    if accounts.canMove(card.id, by: -1) {
                        Button("Move up") { move(card.id, to: index - 1) }
                    }
                    if accounts.canMove(card.id, by: 1) {
                        Button("Move down") { move(card.id, to: index + 1) }
                    }
                }
            }
        }
        .environment(\.isReorderingCards, isReordering)
        .coordinateSpace(.named(Self.space))
        .onChange(of: drag) { _, drag in
            guard let drag else {
                endDrag()
                return
            }
            if !isReordering { isReordering = true }
            guard
                let target = CardReorder.targetIndex(
                    moving: drag.card, to: drag.location, in: shown.map(\.id), frames: frames),
                let next = accounts.dragPreview(moving: drag.card, to: target), next != preview
            else { return }
            withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) { preview = next }
        }
    }

    private func dragGesture(for card: CardID) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
            .updating($drag) { value, state, _ in
                state = CardDrag(card: card, location: value.location)
            }
            .onEnded { _ in drop() }
    }

    /// Moves the dragged card to the place that the preview shows: the one change to the
    /// settings that a drag makes. A card back in its own place changes nothing, and a
    /// preview that no longer fits the cards is dropped.
    private func drop() {
        guard let preview else { return }
        guard accounts.accepts(preview) else {
            withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) { self.preview = nil }
            return
        }
        move(preview.card, to: preview.index, announces: false)
    }

    /// The gesture state resets when the drag ends or is cancelled. A cancelled drag puts the
    /// cards back. This waits one turn, so that a drop that ends the drag applies first. The
    /// mouse-up that ends a drag also reaches the card's header button, so the reorder flag
    /// clears only after that click has been handled.
    private func endDrag() {
        Task { @MainActor in
            if preview != nil {
                withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) { preview = nil }
            }
            try? await Task.sleep(for: .milliseconds(150))
            isReordering = false
        }
    }

    private func move(_ card: CardID, to index: Int, announces: Bool = true) {
        let ids = accounts.cards.map(\.id)
        guard isVisible, ids.indices.contains(index) else {
            preview = nil
            return
        }
        let moved = withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) {
            preview = nil
            return model.moveCard(card, to: index, visible: ids)
        }
        guard moved, announces, let card = accounts.cards.first(where: { $0.id == card }) else {
            return
        }
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

import MeterApp
import SwiftUI

/// The default card for Claude and Codex accounts: a header button with the name and chevron,
/// 88 pt activity rings with one metric row per window, and the details when expanded.
///
/// The card clips its content to its own bounds, so details reveal and hide with the card's
/// height animation.
struct RingCardView: View {
    let card: CardModel
    let rings: RingsModel
    let toggle: () -> Void

    @Environment(\.isReorderingCards) private var isReordering

    private var isExpanded: Bool { card.disclosure.showsDetails }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 14) {
                ActivityRings(
                    outer: .init(fraction: rings.outer.fraction, color: rings.outer.severity.fill),
                    inner: .init(fraction: rings.inner.fraction, color: rings.inner.severity.fill),
                    letter: rings.initial)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rings.rows.enumerated()), id: \.offset) { _, gauge in
                        RingMetricRow(gauge: gauge)
                    }
                }
            }
            if isExpanded {
                DetailSectionsView(sections: card.details)
                    .transition(.reveal)
            }
            if let status = card.status { StatusLineView(status: status) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .chunkyCard()
    }

    private var header: some View {
        Button {
            // The mouse-up that ends a drag lands on this button; it must not toggle.
            guard !isReordering else { return }
            toggle()
        } label: {
            HStack(spacing: 7) {
                CardIdentity(card: card, layout: .spread, fontSize: 15)
                DisclosureChevron(isExpanded: isExpanded)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(showsPress: !isReordering))
        .accessibilityLabel(card.spokenTitle)
        .accessibilityValue(rings.headerAccessibilityValue(isExpanded: isExpanded))
        .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")
        .help(isExpanded ? "Hide \(card.title) details" : "Show \(card.title) details")
    }
}

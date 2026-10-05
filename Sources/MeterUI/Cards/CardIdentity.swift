import MeterApp
import SwiftUI

/// The account name with its plan badge and "same login" chip.
///
/// The name and badges share one line when they fit. Otherwise the badges move below the
/// name, which may wrap to two lines. A tooltip shows the full name.
struct CardIdentity: View {
    enum Layout {
        /// Ring cards: the badges sit at the trailing edge of the card.
        case spread
        /// Bar cards: the badges follow the name, and the row continues after them.
        case compact
    }

    let card: CardModel
    var layout = Layout.compact
    var fontSize: CGFloat = 14

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                name.fixedSize()
                if layout == .spread { Spacer(minLength: 4) }
                badges
            }
            VStack(alignment: .leading, spacing: 4) {
                name
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                badges
            }
        }
    }

    private var name: some View {
        Text(card.title)
            .font(MeterFont.display(fontSize, .semibold))
            .foregroundStyle(Palette.ink)
            .help(card.title)
    }

    @ViewBuilder private var badges: some View {
        if card.plan != nil || card.sharesLogin {
            HStack(spacing: 5) {
                if let plan = card.plan { PlanBadgeView(badge: plan) }
                if card.sharesLogin {
                    ChipView(
                        text: "same login",
                        help: "Two folders are signed in to the same account. They share one quota."
                    )
                }
            }
        }
    }
}

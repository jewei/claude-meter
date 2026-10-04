import MeterApp
import SwiftUI

/// One card, drawn in the style that its summary asks for.
struct CardView: View {
    let card: CardModel
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch card.summary {
        case .rings(let rings):
            RingCardView(card: card, rings: rings)
        case .bars(let bars):
            BarCardView(card: card, bars: bars) {
                withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) {
                    model.toggleCard(card.id)
                }
            }
        case .extraUsage(let extra):
            ExtraUsageCardView(card: card, extra: extra)
        }
    }
}

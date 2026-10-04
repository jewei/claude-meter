import MeterApp
import SwiftUI

/// The default card for Claude and Codex accounts: the name above 88 pt activity rings and
/// one metric row per window. Ring cards always show their details.
struct RingCardView: View {
    let card: CardModel
    let rings: RingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardIdentity(card: card, layout: .spread, fontSize: 15)
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
            DetailSectionsView(sections: card.details)
            if let status = card.status { StatusLineView(status: status) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chunkyCard()
    }
}

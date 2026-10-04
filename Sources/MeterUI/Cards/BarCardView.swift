import MeterApp
import MeterDomain
import SwiftUI

/// A collapsible card: a header button with the provider mark, name, headline percentage,
/// and chevron; one energy bar per window; a caption; and the details when expanded.
///
/// The card clips its content to its own bounds, so details reveal and hide with the card's
/// height animation.
struct BarCardView: View {
    let card: CardModel
    let bars: BarsModel
    let toggle: () -> Void

    private var isExpanded: Bool { card.disclosure.showsDetails }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(Array(bars.bars.enumerated()), id: \.offset) { _, gauge in
                BarRow(gauge: gauge, showsLabels: bars.showsBarLabels)
            }
            if let caption = bars.caption {
                Text(caption)
                    .font(MeterFont.body(11, .semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = card.status { StatusLineView(status: status) }
            if isExpanded {
                DetailSectionsView(sections: card.details)
                    .transition(.reveal)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .chunkyCard()
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                ProviderMark(provider: card.provider)
                CardIdentity(card: card)
                Spacer(minLength: 4)
                Text(bars.headline.valueText)
                    .font(MeterFont.display(14, .bold))
                    .foregroundStyle(bars.headline.severity.headlineInk)
                    .monospacedDigit()
                    .fixedSize()
                DisclosureChevron(isExpanded: isExpanded)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityLabel("\(card.provider.displayName) \(card.title)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")
        .help(isExpanded ? "Hide \(card.title) details" : "Show \(card.title) details")
    }
}

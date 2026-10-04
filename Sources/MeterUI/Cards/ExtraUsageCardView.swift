import MeterApp
import SwiftUI

/// Claude extra usage for the selected account: the amount spent of the monthly limit, and a
/// bar when the share is known.
struct ExtraUsageCardView: View {
    let card: CardModel
    let extra: ExtraUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("💳").font(.system(size: 13)).accessibilityHidden(true)
                Text(card.title)
                    .font(MeterFont.display(14, .semibold))
                    .foregroundStyle(Palette.ink)
                if extra.isPaused { ChipView(text: "paused") }
                Spacer(minLength: 4)
                Text(extra.amountText)
                    .font(MeterFont.display(14, .bold))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                    .fixedSize()
            }
            .frame(minHeight: 22)
            if let fraction = extra.fraction {
                EnergyBar(fraction: fraction, color: Palette.energyFull, height: 12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chunkyCard()
        .accessibilityElement(children: .combine)
    }
}

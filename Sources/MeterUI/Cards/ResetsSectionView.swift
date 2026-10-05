import MeterApp
import SwiftUI

/// "Usage limit resets": the available count, one row per reset with its time to expiry
/// (the exact date is in the tooltip), and a note when details are missing.
struct ResetsSectionView: View {
    let resets: ResetsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Usage limit resets")
                Spacer(minLength: 4)
                Text(resets.countText).monospacedDigit()
            }
            .font(MeterFont.body(11, .bold))
            .foregroundStyle(Palette.ink)
            .accessibilityElement(children: .combine)
            ForEach(Array(resets.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                    Spacer(minLength: 0)
                    Text(row.expiryText)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .font(MeterFont.body(11, .semibold))
                .foregroundStyle(Palette.inkMuted)
                .help(row.help)
                .accessibilityElement(children: .combine)
                .accessibilityHint(row.help)
            }
            if let note = resets.note {
                // The note can count resets ("shown for 2 of 3 resets").
                Text(note)
                    .font(MeterFont.body(10, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

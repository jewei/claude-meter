import MeterApp
import SwiftUI

/// "Tokens used": the source label, Today, Yesterday, and Last 7 Days, and a note when the
/// history is missing, partial, or old. Each count has its full value in a tooltip and in
/// its accessibility value.
struct TokensSectionView: View {
    let tokens: TokenRowsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tokens used")
                    .font(MeterFont.body(11, .bold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                Text(tokens.sourceLabel)
                    .font(MeterFont.body(10, .semibold))
                    .foregroundStyle(Palette.inkMuted)
            }
            .help(tokens.help)
            .accessibilityElement(children: .combine)
            .accessibilityHint(tokens.help)
            ForEach(Array(tokens.rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.title)
                    Spacer(minLength: 4)
                    Text(row.value).monospacedDigit()
                }
                .font(MeterFont.body(11, .semibold))
                .foregroundStyle(Palette.ink)
                .help(row.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.title)
                .accessibilityValue(row.accessibilityValue)
            }
            if let note = tokens.note {
                // A rate-limit note counts down ("Retrying in 3m").
                Text(note)
                    .font(MeterFont.body(10, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

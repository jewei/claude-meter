import MeterApp
import SwiftUI

/// "Tokens used": the source chip, one tile each for Today, Yesterday, and Last 7 days, and a
/// footnote: the estimate note, then the note, after the `+` mark when the note explains it.
/// Each tile has its full count in a tooltip and in its accessibility value.
struct TokensSectionView: View {
    let tokens: TokenRowsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Tokens used")
                    .font(MeterFont.body(11, .bold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                ChipView(text: tokens.sourceLabel)
            }
            .help(tokens.help)
            .accessibilityElement(children: .combine)
            .accessibilityHint(tokens.help)
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(tokens.rows.enumerated()), id: \.offset) { _, row in
                    TokenTile(row: row)
                }
            }
            // Tiles share the height of the tallest.
            .fixedSize(horizontal: false, vertical: true)
            if let footnote = Self.footnote(tokens) {
                // A rate-limit note counts down ("Retrying in 3m").
                Text(footnote)
                    .font(MeterFont.body(10, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `Estimated at API list prices, not a bill. + Partial history — …`, with the `+` in
    /// the low-energy ink. Nil when there is nothing to say.
    static func footnote(_ tokens: TokenRowsModel) -> AttributedString? {
        guard tokens.estimateNote != nil || tokens.note != nil else { return nil }
        var text = AttributedString(tokens.estimateNote ?? "")
        if let note = tokens.note {
            if tokens.estimateNote != nil { text += AttributedString(" ") }
            if tokens.noteExplainsIncomplete {
                var mark = AttributedString("+")
                mark.font = MeterFont.body(10, .extraBold)
                mark.foregroundColor = Palette.energyLowInk
                text += mark + AttributedString(" ")
            }
            text += AttributedString(note)
        }
        return text
    }
}

/// One period: title, the estimate or the count in the display face with `+` when the
/// estimate is incomplete, and the detail below.
private struct TokenTile: View {
    let row: TokenRowsModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title)
                .font(MeterFont.body(10, .bold))
                .foregroundStyle(Palette.inkMuted)
                .lineLimit(1)
            // One text, so the amount and its mark shrink together in a narrow tile.
            Text(Self.value(row))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let detail = row.detail {
                Text(detail)
                    .font(MeterFont.body(10, .semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.popover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1.5)
        )
        .help(row.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(row.accessibilityValue)
    }

    /// The value in the display face, or `—` in the body face one size smaller (the display
    /// face draws the dash like a minus sign), with a raised `+` in the low-energy ink.
    static func value(_ row: TokenRowsModel.Row) -> AttributedString {
        var text = AttributedString(row.value)
        text.font = row.hasValue ? MeterFont.display(18, .bold) : MeterFont.body(17, .bold)
        text.foregroundColor = Palette.ink
        if row.isIncomplete {
            var mark = AttributedString("+")
            mark.font = MeterFont.display(11, .bold)
            mark.foregroundColor = Palette.energyLowInk
            mark.baselineOffset = 5
            text += mark
        }
        return text
    }
}

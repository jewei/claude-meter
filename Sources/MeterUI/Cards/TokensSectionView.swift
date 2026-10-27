import MeterApp
import SwiftUI

/// "Tokens used": the source chip, one tile each for Today, Yesterday, and Last 7 days, and
/// the footnote. Each tile has its full count in a tooltip and in its accessibility value.
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
            if !tokens.footnote.isEmpty {
                // A rate-limit note counts down ("Retrying in 3m").
                Text(Self.footnote(tokens.footnote))
                    .font(MeterFont.body(10, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    // The tiles speak "may be higher"; the mark is not read out.
                    .accessibilityLabel(Self.spokenFootnote(tokens.footnote))
            }
        }
    }

    /// The parts one space apart, with the `+` mark in the low-energy ink.
    static func footnote(_ parts: [TokenRowsModel.FootnotePart]) -> AttributedString {
        var text = AttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { text += AttributedString(" ") }
            switch part {
            case .text(let words):
                text += AttributedString(words)
            case .mark:
                var mark = AttributedString("+")
                mark.font = MeterFont.body(10, .extraBold)
                mark.foregroundColor = Palette.energyLowInk
                text += mark
            }
        }
        return text
    }

    static func spokenFootnote(_ parts: [TokenRowsModel.FootnotePart]) -> String {
        parts.compactMap { if case .text(let words) = $0 { words } else { nil } }
            .joined(separator: " ")
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

import SwiftUI

/// An uppercase label above a group of Settings cards.
struct SectionHeading: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(MeterFont.body(11, .extraBold))
            .tracking(1)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

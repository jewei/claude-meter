import SwiftUI

/// The label of a secondary Settings button: an optional symbol and a title. Use it with
/// `.buttonStyle(.chunky)`, which draws the small chunky surface below the label and the hover
/// and press feedback between the two.
struct ChunkyButtonLabel: View {
    let title: String
    var symbol: String?
    var trailingSymbol: String?

    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold))
            }
            Text(title).font(MeterFont.display(13, .semibold))
            if let trailingSymbol {
                Image(systemName: trailingSymbol).font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 28)
    }
}

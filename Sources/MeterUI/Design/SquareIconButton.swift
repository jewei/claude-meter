import SwiftUI

/// A 28 pt square button with one glyph, a chunky surface, a label, and a tooltip.
struct SquareIconButton: View {
    static let size: CGFloat = 28

    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        let radius = Self.size * 0.3
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: (Self.size * 0.42).rounded(), weight: .bold))
                .foregroundStyle(Palette.inkMuted)
                .frame(width: Self.size, height: Self.size)
        }
        .buttonStyle(QuietButtonStyle(radius: radius, surface: .chunky))
        .accessibilityLabel(label)
        .help(label)
    }
}

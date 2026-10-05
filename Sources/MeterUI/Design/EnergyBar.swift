import SwiftUI

/// A capsule bar whose fill length is the energy share.
///
/// A narrow highlight runs along the top of the fill. It appears only when the fill is wider
/// than ``highlightMinimumWidth``, so a near-empty bar never looks like it holds energy.
struct EnergyBar: View {
    /// The fill width below which the top highlight is hidden.
    static let highlightMinimumWidth: CGFloat = 6

    var fraction: Double
    var color: Color
    var height: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.popoverIsVisible) private var isVisible

    var body: some View {
        GeometryReader { geometry in
            let width = Self.fillWidth(fraction: fraction, in: geometry.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(color)
                    .frame(width: width)
                    .overlay(alignment: .top) {
                        if Self.showsHighlight(fillWidth: width) {
                            Capsule()
                                .fill(Color.white.opacity(0.45))
                                .frame(height: min(2, height / 4))
                                .padding(.horizontal, 3)
                                .padding(.top, 2)
                        }
                    }
            }
            // The track's shape clips the fill, so a tiny fill follows the rounded end.
            .clipShape(Capsule())
        }
        .frame(height: height)
        .animation(Motion.value(reduceMotion: reduceMotion || !isVisible), value: fraction)
        .accessibilityHidden(true)
    }

    /// The fill width for a share, clamped to 0...1. Non-finite shares fill nothing.
    static func fillWidth(fraction: Double, in width: CGFloat) -> CGFloat {
        guard fraction.isFinite, width.isFinite, width > 0 else { return 0 }
        return width * CGFloat(min(1, max(0, fraction)))
    }

    static func showsHighlight(fillWidth: CGFloat) -> Bool {
        fillWidth > highlightMinimumWidth
    }
}

import SwiftUI

/// A capsule bar whose fill length is the energy share.
///
/// The track is recessed with a soft inner shadow. The fill is lighter at the top and has a
/// darker band along its bottom edge. A narrow highlight runs along the top of the fill. It
/// appears only when the fill is wider than ``highlightMinimumWidth``, so a near-empty bar
/// never looks like it holds energy.
struct EnergyBar: View {
    /// The fill width below which the top highlight is hidden.
    static let highlightMinimumWidth: CGFloat = 6
    /// How far the shortfall reaches under the rounded end of the fill, so no gap shows.
    static let shortfallOverlap: CGFloat = 8

    var fraction: Double
    var color: Color
    var height: CGFloat = 12
    /// Where an even pace would be, 0...1, drawn as a ``PaceMark``. Nil draws none.
    var mark: Double? = nil
    /// The color of the shortfall: hatching from the end of the fill to a mark beyond it.
    /// Nil draws none.
    var shortfall: Color? = nil
    /// A ring inside the track, for a window with no energy left. Nil draws none.
    var outline: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.popoverIsVisible) private var isVisible

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillWidth = Self.fillWidth(fraction: fraction, in: width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        Palette.track.shadow(
                            .inner(color: .black.opacity(0.08), radius: 0.5, y: 1.5)))
                if let shortfall,
                    let span = Self.shortfallSpan(fraction: fraction, mark: mark, in: width)
                {
                    ShortfallHatch(color: shortfall)
                        .frame(width: span.upperBound - span.lowerBound)
                        // The stripes are slanted; their ends must stop at the mark.
                        .clipped()
                        .offset(x: span.lowerBound)
                }
                fill(width: fillWidth)
            }
            // The track's shape clips the fill, so a tiny fill follows the rounded end.
            .clipShape(Capsule())
            .overlay {
                if let outline { Capsule().strokeBorder(outline, lineWidth: 1.5) }
            }
        }
        .frame(height: height)
        .animation(Motion.value(reduceMotion: reduceMotion || !isVisible), value: fraction)
        .overlay(alignment: .leading) {
            if let mark {
                GeometryReader { geometry in
                    let style = Self.markStyle(
                        fraction: fraction, mark: mark, in: geometry.size.width, height: height)
                    PaceMark(length: style == .onFill ? height : height + 4, style: style)
                        .position(
                            // Inside the capsule at either end: the mark is up to 4 pt wide.
                            x: min(
                                max(2, Self.fillWidth(fraction: mark, in: geometry.size.width)),
                                geometry.size.width - 2),
                            y: geometry.size.height / 2
                        )
                        .noShareAnimation(mark)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            color
            LinearGradient(
                colors: [.white.opacity(0.16), .white.opacity(0)], startPoint: .top,
                endPoint: .bottom)
            Color.black.opacity(0.1).frame(height: min(3, height / 4.5))
        }
        .frame(width: width)
        .clipShape(Capsule())
        .overlay(alignment: .top) {
            if Self.showsHighlight(fillWidth: width) {
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(height: min(3, height / 4))
                    .padding(.horizontal, min(6, width / 4))
                    .padding(.top, min(2.5, height / 5))
            }
        }
    }

    /// The fill width for a share, clamped to 0...1. Non-finite shares fill nothing.
    static func fillWidth(fraction: Double, in width: CGFloat) -> CGFloat {
        guard fraction.isFinite, width.isFinite, width > 0 else { return 0 }
        return width * CGFloat(min(1, max(0, fraction)))
    }

    static func showsHighlight(fillWidth: CGFloat) -> Bool {
        fillWidth > highlightMinimumWidth
    }

    /// From under the end of the fill to the mark, when the mark is beyond the fill. Nil
    /// without a mark, or when the mark is on the fill.
    static func shortfallSpan(
        fraction: Double, mark: Double?, in width: CGFloat
    ) -> ClosedRange<CGFloat>? {
        guard let mark else { return nil }
        let fillEnd = fillWidth(fraction: fraction, in: width)
        let markAt = fillWidth(fraction: mark, in: width)
        guard markAt > fillEnd else { return nil }
        return max(0, fillEnd - shortfallOverlap)...markAt
    }

    /// White where the mark is on the fill and clear of the rounded ends, so the bar-high line
    /// stays inside the capsule and on the fill. Elsewhere half ink with a halo, which also
    /// reads on the track and past the ends.
    static func markStyle(
        fraction: Double, mark: Double, in width: CGFloat, height: CGFloat
    ) -> PaceMark.Style {
        let markAt = fillWidth(fraction: mark, in: width)
        let fillEnd = fillWidth(fraction: fraction, in: width)
        let radius = height / 2
        return markAt >= radius && markAt <= fillEnd - radius ? .onFill : .onTrack
    }
}

/// Diagonal stripes on a light wash, both in the shortfall color.
private struct ShortfallHatch: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.1)))
            // 45° stripes, 2 pt wide and 5 pt apart measured across them.
            let stripe: CGFloat = 2 * 2.squareRoot()
            let period: CGFloat = 5 * 2.squareRoot()
            var stripes = Path()
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + stripe, y: size.height))
                stripes.addLine(to: CGPoint(x: x + stripe + size.height, y: 0))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                stripes.closeSubpath()
                x += period
            }
            context.fill(stripes, with: .color(color.opacity(0.42)))
        }
    }
}

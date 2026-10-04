import SwiftUI

/// Two concentric rings: the outer ring is the weekly window (radius 34), the inner ring is
/// the session window (radius 24). Both use 8 pt round-capped strokes that start at the top.
/// A neutral disc in the center holds the account letter.
///
/// Sizes scale from the 88 pt design. The view is hidden from accessibility; the card reads
/// the values in its rows.
struct ActivityRings: View {
    struct Ring: Equatable {
        var fraction: Double
        var color: Color
    }

    var outer: Ring
    var inner: Ring
    var letter: String
    var size: CGFloat = 88

    var body: some View {
        let scale = size / 88
        ZStack {
            RingArc(ring: outer, diameter: 68 * scale, lineWidth: 8 * scale)
            RingArc(ring: inner, diameter: 48 * scale, lineWidth: 8 * scale)
            if !letter.isEmpty {
                Circle()
                    .fill(Palette.popover)
                    .overlay(Circle().strokeBorder(Palette.cardBorder.opacity(0.7), lineWidth: 1))
                    .frame(width: 30 * scale, height: 30 * scale)
                Text(letter)
                    .font(MeterFont.display(19 * scale, .bold))
                    .foregroundStyle(Palette.ink)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One ring: the track, the arc, and a directional highlight along the arc.
private struct RingArc: View {
    let ring: ActivityRings.Ring
    let diameter: CGFloat
    let lineWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fill = ring.fraction.isFinite ? min(1, max(0, ring.fraction)) : 0
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(ring.color, style: style)
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: fill)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .clear], startPoint: .trailing,
                        endPoint: .leading),
                    style: style
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .animation(Motion.value(reduceMotion: reduceMotion), value: fill)
    }
}

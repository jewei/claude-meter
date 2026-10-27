import SwiftUI

/// The even-pace mark. A change of its share does not animate: it moves with the clock, and a
/// slide on each render would draw the eye for no reason. The parent applies that with
/// ``noShareAnimation(_:)``, so the mark still moves with its bar or ring when a card opens or
/// moves.
struct PaceMark: View {
    enum Style: Equatable {
        /// A 2 pt ink line with a 1 pt card-colored edge on each side, so it reads on the
        /// track and on every fill color in both appearances. Rings use it.
        case edged
        /// A 2 pt white line inside a bar's fill, as long as the bar is high.
        case onFill
        /// A 2 pt line in half ink on a bar's track, with a 1 pt card-colored halo.
        case onTrack
    }

    /// The length across the bar or ring stroke.
    var length: CGFloat
    var style = Style.edged

    var body: some View {
        Group {
            switch style {
            case .edged:
                Rectangle()
                    .fill(Palette.ink)
                    .frame(width: 2, height: length)
                    .padding(.horizontal, 1)
                    .background(Palette.card)
            case .onFill:
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: length)
            case .onTrack:
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.ink.opacity(0.5))
                    .frame(width: 2, height: length)
                    .padding(1)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Palette.card.opacity(0.9), lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Turns off animation only for a change of `share`, never for the layout around it.
    func noShareAnimation(_ share: Double) -> some View {
        transaction(value: share) { $0.animation = nil }
    }
}

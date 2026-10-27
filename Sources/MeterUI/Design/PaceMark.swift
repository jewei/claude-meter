import SwiftUI

/// The even-pace mark: a 2 pt ink line with a 1 pt card-colored edge on each side, so it reads
/// on the track and on every fill color in both appearances. A change of its share does not
/// animate: it moves with the clock, and a slide on each render would draw the eye for no
/// reason. The parent applies that with ``noShareAnimation(_:)``, so the mark still moves with
/// its bar or ring when a card opens or moves.
struct PaceMark: View {
    /// The length across the bar or ring stroke.
    var length: CGFloat

    var body: some View {
        Rectangle()
            .fill(Palette.ink)
            .frame(width: 2, height: length)
            .padding(.horizontal, 1)
            .background(Palette.card)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Turns off animation only for a change of `share`, never for the layout around it.
    func noShareAnimation(_ share: Double) -> some View {
        transaction(value: share) { $0.animation = nil }
    }
}

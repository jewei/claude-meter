import SwiftUI

/// The even-pace mark: a 2 pt ink line with a 1 pt card-colored edge on each side, so it reads
/// on the track and on every fill color in both appearances. It never animates: it moves with
/// the clock, and a slide on each render would draw the eye for no reason.
struct PaceMark: View {
    /// The length across the bar or ring stroke.
    var length: CGFloat

    var body: some View {
        Rectangle()
            .fill(Palette.ink)
            .frame(width: 2, height: length)
            .padding(.horizontal, 1)
            .background(Palette.card)
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
    }
}

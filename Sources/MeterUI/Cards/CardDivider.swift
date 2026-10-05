import SwiftUI

/// The 1 pt rule between card sections.
struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.cardBorder)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

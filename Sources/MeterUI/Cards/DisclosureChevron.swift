import SwiftUI

/// The chevron of a collapsible card: down when open, right when closed. It turns with the
/// card's disclosure animation.
struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Palette.inkMuted)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

import SwiftUI

/// A Settings page: the title and subtitle, then the sections, in a scroll view with 24 pt
/// insets.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    var spacing: CGFloat = 18
    @ViewBuilder let content: Content

    @Environment(\.rendersStatically) private var rendersStatically

    var body: some View {
        let page = VStack(alignment: .leading, spacing: spacing) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(MeterFont.display(26, .bold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(MeterFont.body(13, .semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        if rendersStatically {
            page
        } else {
            ScrollView(.vertical) { page }
        }
    }
}

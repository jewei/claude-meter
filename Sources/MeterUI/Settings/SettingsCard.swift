import SwiftUI

/// A chunky Settings card with 16 pt padding. Rows inside are separated by ``CardDivider``.
struct SettingsCard<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chunkyCard(radius: 18)
    }
}

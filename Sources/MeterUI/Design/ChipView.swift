import SwiftUI

/// A small neutral chip, such as "same login" or "paused".
struct ChipView: View {
    let text: String
    var help: String?

    var body: some View {
        Text(text)
            .font(MeterFont.body(10, .bold))
            .foregroundStyle(Palette.inkMuted)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Palette.track))
            .modifier(OptionalHelp(text: help))
    }
}

/// A tooltip only when there is text for it; `.help("")` shows an empty one.
struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

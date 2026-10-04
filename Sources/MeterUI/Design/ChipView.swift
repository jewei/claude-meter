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
            .help(help ?? "")
    }
}

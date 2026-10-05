import SwiftUI

/// The neutral pill above the card that owns the menu bar.
struct MenuBarPill: View {
    var body: some View {
        Label("Menu bar", systemImage: "menubar.rectangle")
            .font(MeterFont.body(10, .extraBold))
            .foregroundStyle(Palette.inkMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.track.opacity(0.65)))
            .padding(.leading, 2)
    }
}

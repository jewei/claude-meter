import SwiftUI

/// A native switch with the accent tint and a spoken label. Its visible label lives in the
/// row beside it.
struct MeterSwitch: View {
    let label: String
    @Binding var isOn: Bool

    @Environment(\.rendersStatically) private var rendersStatically
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if rendersStatically {
            // `ImageRenderer` cannot draw AppKit controls. This shape matches the switch.
            Capsule()
                .fill(isOn ? Palette.accent : Palette.track)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.15), radius: 1)
                }
                .opacity(isEnabled ? 1 : 0.45)
        } else {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Palette.accent)
                .accessibilityLabel(label)
        }
    }
}

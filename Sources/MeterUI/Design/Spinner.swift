import SwiftUI

/// The native indeterminate spinner. It stops while the popover is hidden and draws as a
/// static ring when rendered to an image.
struct Spinner: View {
    @Environment(\.rendersStatically) private var rendersStatically
    @Environment(\.popoverIsVisible) private var isVisible

    var body: some View {
        if rendersStatically || !isVisible {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Palette.inkMuted, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 18, height: 18)
                .padding(2)
                .accessibilityLabel("Loading")
        } else {
            ProgressView().controlSize(.regular).scaleEffect(0.9)
        }
    }
}

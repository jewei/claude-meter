import SwiftUI

/// Feedback for compact controls: a faint ink surface on hover and press, a 2 pt focus
/// border, and 45% opacity when disabled. Nothing moves.
struct QuietButtonStyle: ButtonStyle {
    var radius: CGFloat = 8
    /// False while the button is being dragged with its card, so it does not look pressed.
    var showsPress = true

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, radius: radius, showsPress: showsPress)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let radius: CGFloat
        let showsPress: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .background(shape.fill(Palette.ink.opacity(surfaceOpacity)))
                .overlay {
                    shape.strokeBorder(isFocused ? Palette.accent : .clear, lineWidth: 2)
                }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }

        private var surfaceOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed, showsPress { return 0.12 }
            return isHovered ? 0.06 : 0
        }
    }
}

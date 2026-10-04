import SwiftUI

/// The primary button: a dark green fill on a solid shadow plate that compresses on press.
///
/// The label moves down 2 pt and the plate moves from 4 pt to 2 pt when pressed. Reduce
/// Motion keeps the button still and darkens it instead.
struct RaisedButtonStyle: ButtonStyle {
    var fill: Color = Palette.action
    var shadow: Color = Palette.actionShadow
    var radius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, fill: fill, shadow: shadow, radius: radius)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let fill: Color
        let shadow: Color
        let radius: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var isHovered = false

        private var isPressed: Bool { isEnabled && configuration.isPressed }
        private var moves: Bool { isPressed && !reduceMotion }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .font(MeterFont.display(14, .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(shape.fill(fill))
                .overlay {
                    shape.fill(pressTint).allowsHitTesting(false)
                }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .clear], startPoint: .top,
                            endPoint: .bottom),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
                .offset(y: moves ? 2 : 0)
                .background(shape.fill(shadow).offset(y: moves ? 2 : 4))
                .overlay {
                    RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                        .strokeBorder(isFocused ? Palette.accent : .clear, lineWidth: 2)
                        .padding(-4)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
                .animation(Motion.press(reduceMotion: reduceMotion), value: isPressed)
        }

        private var pressTint: Color {
            if isPressed { return .black.opacity(reduceMotion ? 0.16 : 0.08) }
            return .white.opacity(isHovered && isEnabled ? 0.06 : 0)
        }
    }
}

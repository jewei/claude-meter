import SwiftUI

/// Feedback for compact controls: a faint ink surface on hover and press, a 2 pt focus
/// border, and 45% opacity when disabled. Nothing moves.
///
/// The style draws the button's own fill (``Surface``), then the ink surface, then the
/// label. A label must not draw an opaque fill of its own: that fill would hide the hover and
/// press surface. Give the fill to the style instead.
struct QuietButtonStyle: ButtonStyle {
    /// What the button stands on, below the hover and press surface.
    enum Surface {
        /// Nothing: the button shows what is behind it.
        case clear
        /// A ``ChunkyCard`` with the button's radius.
        case chunky
        /// A flat fill with the button's radius.
        case fill(Color)
    }

    /// The ink surface on hover. Muted text keeps 4.5:1 on it.
    static let hoverOpacity = 0.06
    /// The ink surface while pressed. Muted text keeps 4.5:1 on it.
    static let pressOpacity = 0.10

    var radius: CGFloat = 8
    var surface: Surface = .clear
    /// False while the button is being dragged with its card, so it does not look pressed.
    var showsPress = true

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(
            isPressed: configuration.isPressed && showsPress, radius: radius, surface: surface
        ) {
            configuration.label
        }
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    /// A small chunky button, for ``ChunkyButtonLabel``.
    static var chunky: QuietButtonStyle { QuietButtonStyle(radius: 12, surface: .chunky) }
}

/// What ``QuietButtonStyle`` draws, apart from the button, so a test can draw it pressed.
struct QuietButtonBody<Label: View>: View {
    let isPressed: Bool
    let radius: CGFloat
    let surface: QuietButtonStyle.Surface
    @ViewBuilder let label: Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        label
            .background(shape.fill(Palette.ink.opacity(surfaceOpacity)))
            .modifier(SurfaceFill(surface: surface, radius: radius))
            .overlay {
                shape.strokeBorder(isFocused ? Palette.accent : .clear, lineWidth: 2)
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }

    private var surfaceOpacity: Double {
        guard isEnabled else { return 0 }
        if isPressed { return QuietButtonStyle.pressOpacity }
        return isHovered ? QuietButtonStyle.hoverOpacity : 0
    }
}

/// The button's own fill, below the hover and press surface.
private struct SurfaceFill: ViewModifier {
    let surface: QuietButtonStyle.Surface
    let radius: CGFloat

    func body(content: Content) -> some View {
        switch surface {
        case .clear:
            content
        case .chunky:
            content.chunkyCard(radius: radius)
        case .fill(let color):
            content.background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color))
        }
    }
}

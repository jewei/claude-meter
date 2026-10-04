import SwiftUI

/// The raised card surface: a solid lower plate 3 pt below, the fill, a light top wash, a
/// 2 pt border, and a 1 pt inner top highlight.
struct ChunkyCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    var fill: Color = Palette.card
    var border: Color = Palette.cardBorder
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.fill(Palette.cardLip).offset(y: 3)
                shape.fill(fill)
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.06 : 0.12), .clear],
                        startPoint: .top, endPoint: .bottom))
                shape.strokeBorder(border, lineWidth: 2)
                RoundedRectangle(cornerRadius: max(0, radius - 2), style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .clear], startPoint: .top,
                            endPoint: .center),
                        lineWidth: 1
                    )
                    .padding(2)
            }
        }
    }
}

extension View {
    /// Puts the content on a ``ChunkyCard`` surface.
    func chunkyCard(
        fill: Color = Palette.card, border: Color = Palette.cardBorder, radius: CGFloat = 18
    ) -> some View {
        modifier(ChunkyCard(fill: fill, border: border, radius: radius))
    }
}

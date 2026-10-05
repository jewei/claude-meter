import SwiftUI

/// Reveals card details from the top down, and hides them from the bottom up, so they stay
/// visible while the card grows and shrinks around them.
struct RevealTransition: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            Rectangle().scaleEffect(x: 1, y: progress, anchor: .top)
        }
    }
}

extension AnyTransition {
    /// A top-anchored mask that grows with the card's disclosure animation.
    static var reveal: AnyTransition {
        .modifier(active: RevealTransition(progress: 0), identity: RevealTransition(progress: 1))
    }
}

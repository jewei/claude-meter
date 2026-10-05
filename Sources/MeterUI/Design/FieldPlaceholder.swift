import SwiftUI

extension View {
    /// Draws `text` in `inkMuted` over an empty text field, in place of the system
    /// placeholder, whose color is below 4.5:1 on the popover and card fills. Give the field
    /// an empty prompt. The text is hidden from VoiceOver; give the field a hint instead.
    func fieldPlaceholder(_ text: String, isShown: Bool, font: Font) -> some View {
        overlay(alignment: .leading) {
            if isShown {
                Text(text)
                    .font(font)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

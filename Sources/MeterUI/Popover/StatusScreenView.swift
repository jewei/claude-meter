import MeterApp
import SwiftUI

/// A full-size message with one action: welcome, paused, nothing set up, or an error.
///
/// The mascot sits in a raised 76 pt disc and is hidden from accessibility. The message wraps
/// without a line limit; inline code in it (`codex login`) renders as code.
struct StatusScreenView: View {
    let screen: StatusScreen
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(screen.emoji)
                .font(.system(size: 36))
                .frame(width: 76, height: 76)
                .background(Circle().fill(Palette.card))
                .overlay(Circle().strokeBorder(Palette.cardBorder, lineWidth: 2))
                .background(Circle().fill(Palette.cardLip).offset(y: 3))
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(screen.title)
                    .font(MeterFont.display(20, .semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.message(screen.message))
                    .font(MeterFont.body(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkMuted)
                    .lineSpacing(2)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button(screen.actionTitle, action: action)
                .buttonStyle(RaisedButtonStyle())
                .fixedSize()
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 32)
        .padding(.horizontal, 22)
    }

    /// The message with Markdown inline code in a small monospaced face, or the plain text
    /// when it does not parse.
    static func message(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var message = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in message.runs where run.inlinePresentationIntent?.contains(.code) == true {
            message[run.range].font = .system(size: 11, weight: .semibold, design: .monospaced)
        }
        return message
    }
}

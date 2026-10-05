import SwiftUI

/// A labeled token field: a secure field while hidden, a plain field when shown. While it is
/// empty it says "Paste here" in `inkMuted` (`fieldPlaceholder`); VoiceOver hears ``hint``.
struct TokenField: View {
    static let placeholder = "Paste here"
    static let hint = "Paste the token here."

    let title: String
    @Binding var text: String
    let isRevealed: Bool

    @Environment(\.rendersStatically) private var rendersStatically
    @FocusState private var isFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MeterFont.body(11, .bold))
                .foregroundStyle(Palette.ink)
                .accessibilityHidden(true)
            field
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(Self.font)
                .foregroundStyle(Palette.ink)
                .fieldPlaceholder(Self.placeholder, isShown: text.isEmpty, font: Self.font)
                .focused($isFocused)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(Palette.card))
                .overlay(
                    shape.strokeBorder(
                        isFocused ? Palette.accent : Palette.cardBorder, lineWidth: 1.5)
                )
                .accessibilityLabel(title)
                // The drawn placeholder is hidden from VoiceOver (`fieldPlaceholder`).
                .accessibilityHint(Self.hint)
        }
    }

    private static let font = Font.system(size: 12, design: .monospaced)

    @ViewBuilder private var field: some View {
        if rendersStatically {
            // A space keeps the line height of an empty field.
            Text(text.isEmpty ? " " : String(repeating: "•", count: min(24, text.count)))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if isRevealed {
            TextField(title, text: $text, prompt: Text(""))
        } else {
            SecureField(title, text: $text, prompt: Text(""))
        }
    }
}

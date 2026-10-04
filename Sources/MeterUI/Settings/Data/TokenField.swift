import SwiftUI

/// A labeled token field: a secure field while hidden, a plain field when shown.
struct TokenField: View {
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
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.ink)
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
        }
    }

    @ViewBuilder private var field: some View {
        if rendersStatically {
            Text(text.isEmpty ? "Paste here" : String(repeating: "•", count: min(24, text.count)))
                .foregroundStyle(Palette.inkMuted)
        } else if isRevealed {
            TextField(title, text: $text, prompt: Text("Paste here"))
        } else {
            SecureField(title, text: $text, prompt: Text("Paste here"))
        }
    }
}

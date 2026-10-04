import SwiftUI

/// A bordered field for an account's display name. It saves when the user presses Return or
/// leaves the field, not on every key, and shows the default name as a placeholder.
struct DisplayNameField: View {
    let name: String?
    let placeholder: String
    let save: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @Environment(\.rendersStatically) private var rendersStatically

    var body: some View {
        field
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(MeterFont.display(14, .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.popover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isFocused ? Palette.accent : Palette.cardBorder, lineWidth: 1.5)
            )
            .focused($isFocused)
            .accessibilityLabel("Display name")
            .onAppear { draft = name ?? "" }
            .onChange(of: name) { _, name in
                if !isFocused { draft = name ?? "" }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit(commit)
    }

    @ViewBuilder private var field: some View {
        if rendersStatically {
            Text(name ?? placeholder)
                .foregroundStyle(name == nil ? Palette.inkMuted : Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Display name", text: $draft, prompt: Text(placeholder))
        }
    }

    private func commit() {
        guard draft != (name ?? "") else { return }
        save(draft)
    }
}

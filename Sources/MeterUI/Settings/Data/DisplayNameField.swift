import SwiftUI

/// A bordered field for an account's display name. It saves when the user presses Return,
/// leaves the field, leaves the page or the window, or quits, not on every key.
///
/// While the field is empty it shows the default name in `inkMuted` on top of it. The system
/// placeholder color is too light for 4.5:1 on the popover fill.
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
            .fieldPlaceholder(
                placeholder, isShown: shownText.isEmpty, font: MeterFont.display(14, .semibold)
            )
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
            .accessibilityHint("Leave it empty to use \(placeholder).")
            .onAppear { draft = name ?? "" }
            .onChange(of: name) { _, name in
                if !isFocused { draft = name ?? "" }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit(commit)
            // A tab change, Command-1…4, or closing the window removes the field without a
            // focus change; Quit removes nothing. Keep the name in each case.
            .onDisappear(perform: commit)
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            ) { _ in commit() }
    }

    /// The text in the field. A static render has no draft, so it shows the saved name.
    private var shownText: String {
        rendersStatically ? name ?? "" : draft
    }

    @ViewBuilder private var field: some View {
        if rendersStatically {
            // A space keeps the line height of an empty field.
            Text(shownText.isEmpty ? " " : shownText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // An empty prompt: the overlay draws the default name.
            TextField("Display name", text: $draft, prompt: Text(""))
        }
    }

    private func commit() {
        guard draft != (name ?? "") else { return }
        save(draft)
    }
}

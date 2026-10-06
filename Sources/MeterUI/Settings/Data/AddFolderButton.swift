import SwiftUI

/// "Add config dir…" for Claude and Codex: a chunky button with a folder symbol.
struct AddFolderButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChunkyButtonLabel(title: title, symbol: "folder.badge.plus")
        }
        .buttonStyle(.chunky)
    }
}

import SwiftUI

/// "Add config dir…" and "Add Codex home…": a chunky button with a folder symbol.
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

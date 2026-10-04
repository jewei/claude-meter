import MeterApp
import MeterDomain
import SwiftUI

/// One Codex home: its name, folder, and sign-in state, with Remove for homes that the user
/// added.
struct CodexHomeRow: View {
    let home: CodexSettingsModel.Home
    let name: String?
    let rename: (String) -> Void
    let remove: () -> Void

    var body: some View {
        FolderRow(id: home.id.rawValue, name: name, defaultName: home.defaultName, rename: rename) {
            PathChip(path: home.path)
            SignInStatusLine(status: DataSourceText.codexHome(home.status))
        } controls: {
            if !home.isImplicit {
                RemoveButton(name: name ?? home.defaultName, action: remove)
            }
        }
    }
}

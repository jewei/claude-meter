import MeterApp
import MeterDomain
import SwiftUI

/// The Codex homes list and "Add Codex home…".
struct CodexSourceSection: View {
    let codex: CodexSettingsModel
    let names: [AccountID: String]

    var body: some View {
        CodexHomesList(
            homes: codex.homes, names: names, isLoading: codex.isLoading, error: codex.error,
            rename: { codex.rename($0, to: $1) }, remove: { codex.removeHome($0) },
            add: {
                Task {
                    guard
                        let url = await FolderPicker.chooseFolder(
                            title: "Add Codex Home",
                            message:
                                "Choose a Codex home: a folder with auth.json, such as ~/.codex.")
                    else { return }
                    await codex.addHome(url)
                }
            })
    }
}

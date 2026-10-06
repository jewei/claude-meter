import MeterApp
import MeterDomain
import SwiftUI

/// The Codex homes list and "Add config dir…".
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
                            title: "Add Config Dir",
                            message:
                                "Choose a Codex config dir: a folder with auth.json, such as ~/.codex."
                        )
                    else { return }
                    await codex.addHome(url)
                }
            })
    }
}

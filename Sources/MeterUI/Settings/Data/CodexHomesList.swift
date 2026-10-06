import MeterApp
import MeterDomain
import SwiftUI

/// The homes, a loading line before the first list, the add button, and the last error.
struct CodexHomesList: View {
    let homes: [CodexSettingsModel.Home]
    let names: [AccountID: String]
    let isLoading: Bool
    let error: String?
    let rename: (AccountID, String) -> Void
    let remove: (AccountID) -> Void
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each config dir is one Codex login.")
                .font(MeterFont.body(12, .semibold))
                .foregroundStyle(Palette.inkMuted)
            ForEach(homes) { home in
                CodexHomeRow(
                    home: home, name: names[home.id], rename: { rename(home.id, $0) },
                    remove: { remove(home.id) })
            }
            if homes.isEmpty, isLoading {
                Text("Looking for config dirs…")
                    .font(MeterFont.body(12, .semibold))
                    .foregroundStyle(Palette.inkMuted)
            }
            AddFolderButton(title: "Add config dir…", action: add)
            if let error {
                Text(error)
                    .font(MeterFont.body(11, .bold))
                    .foregroundStyle(Palette.energyEmptyInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

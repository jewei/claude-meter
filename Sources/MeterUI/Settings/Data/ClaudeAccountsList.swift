import MeterApp
import MeterDomain
import SwiftUI

/// The config dirs and "Add config dir…".
struct ClaudeAccountsList: View {
    let accounts: [ClaudeSettingsModel.Account]
    let names: [AccountID: String]
    let planOverrides: [AccountID: String]
    let rename: (AccountID, String) -> Void
    let setEnabled: (AccountID, Bool) -> Void
    let setPlan: (AccountID, String?) -> Void
    let remove: (AccountID) -> Void
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each config dir is one Claude Code login.")
                .font(MeterFont.body(12, .semibold))
                .foregroundStyle(Palette.inkMuted)
            ForEach(accounts) { account in
                ClaudeAccountRow(
                    account: account, name: names[account.id],
                    planOverride: planOverrides[account.id],
                    rename: { rename(account.id, $0) },
                    setEnabled: { setEnabled(account.id, $0) },
                    setPlan: { setPlan(account.id, $0) },
                    remove: { remove(account.id) })
            }
            AddFolderButton(title: "Add config dir…", action: add)
        }
    }
}

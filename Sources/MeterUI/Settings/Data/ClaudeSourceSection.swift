import MeterApp
import MeterDomain
import SwiftUI

/// Claude's controls in Settings > Data: the connection, then the config dirs while the
/// connection is automatic.
struct ClaudeSourceSection: View {
    let claude: ClaudeSettingsModel
    let settings: ClaudeSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClaudeConnectionView(snapshot: snapshot, actions: actions)
            if claude.connection == .automatic {
                CardDivider()
                ClaudeAccountsList(
                    accounts: claude.accounts, names: settings.accountNames,
                    planOverrides: settings.planOverrides,
                    rename: { claude.rename($0, to: $1) },
                    setEnabled: { claude.setEnabled($0, $1) },
                    setPlan: { claude.setPlanOverride($0, $1) },
                    remove: { claude.removeDirectory($0) },
                    add: addDirectory)
            }
        }
    }

    private var snapshot: ClaudeConnectionView.Snapshot {
        ClaudeConnectionView.Snapshot(
            connection: claude.connection, automaticStatus: claude.automaticStatus,
            manualStatus: claude.manualStatus, isWorking: claude.isWorking,
            message: claude.message, needsKeychainConsent: claude.needsKeychainConsent)
    }

    private var actions: ClaudeConnectionView.Actions {
        ClaudeConnectionView.Actions(
            connectAutomatically: { await claude.connectAutomatically() },
            connectManually: { access, refresh, expiry in
                await claude.connectManually(
                    accessToken: access, refreshToken: refresh, expiresAt: expiry)
                // The model reports success only through its message.
                return claude.connection == .manual && claude.message == "Connected."
            },
            disconnect: { await claude.disconnect() })
    }

    private func addDirectory() {
        guard
            let url = FolderPicker.chooseFolder(
                title: "Add Config Dir",
                message:
                    "Choose a Claude config dir: a folder with settings.json, such as ~/.claude.")
        else { return }
        claude.addDirectory(url)
    }
}

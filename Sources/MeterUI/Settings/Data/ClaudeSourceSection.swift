import MeterApp
import MeterDomain
import SwiftUI

/// Claude's controls in Settings > Data: the connection, then the config dirs while the
/// connection is automatic, or the plan badge while it is manual.
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
                    add: addDirectory, message: claude.directoryMessage)
            } else if claude.connection == .manual {
                CardDivider()
                HStack(spacing: 8) {
                    Text("Plan")
                        .font(MeterFont.body(12, .semibold))
                        .foregroundStyle(Palette.inkMuted)
                    switch claude.manualPlan {
                    case .reported(let badge): PlanBadgeView(badge: badge)
                    case .pickable(let current):
                        PlanMenu(current: current, choose: { claude.setManualPlan($0) })
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var snapshot: ClaudeConnectionView.Snapshot {
        ClaudeConnectionView.Snapshot(
            connection: claude.connection, automaticStatus: claude.automaticStatus,
            manualStatus: claude.manualStatus, isWorking: claude.isWorking,
            message: claude.message, messageIsProblem: claude.messageIsProblem,
            needsKeychainConsent: claude.needsKeychainConsent)
    }

    private var actions: ClaudeConnectionView.Actions {
        ClaudeConnectionView.Actions(
            connectAutomatically: { await claude.connectAutomatically() },
            connectManually: { access, refresh, expiry in
                await claude.connectManually(
                    accessToken: access, refreshToken: refresh, expiresAt: expiry)
            },
            abandonConnect: { await claude.abandonConnect() },
            disconnect: { await claude.disconnect() })
    }

    private func addDirectory() {
        Task {
            guard
                let url = await FolderPicker.chooseFolder(
                    title: "Add Config Dir",
                    message:
                        "Choose a Claude config dir: a folder with settings.json, such as ~/.claude."
                )
            else { return }
            await claude.addDirectory(url)
        }
    }
}

import MeterApp
import MeterDomain
import SwiftUI

/// One Claude login: its name, config dir, plan, and issue, with a tracking switch where the
/// login can be turned off and Remove for folders that the user added.
struct ClaudeAccountRow: View {
    let account: ClaudeSettingsModel.Account
    let name: String?
    let planOverride: String?
    let rename: (String) -> Void
    let setEnabled: (Bool) -> Void
    let setPlan: (String?) -> Void
    let remove: () -> Void

    var body: some View {
        FolderRow(
            id: account.id.rawValue, name: name, defaultName: account.defaultName, rename: rename
        ) {
            HStack(spacing: 6) {
                if let path = account.path {
                    PathChip(path: path)
                } else {
                    Text("Active login, no config dir")
                        .font(MeterFont.body(11, .semibold))
                        .foregroundStyle(Palette.inkMuted)
                }
                if let badge = PlanBadge(plan: account.reportedPlan) {
                    PlanBadgeView(badge: badge)
                } else {
                    PlanMenu(current: planOverride, choose: setPlan)
                }
            }
            if let issue = account.issue {
                Text(issue)
                    .font(MeterFont.body(11, .bold))
                    .foregroundStyle(Palette.energyEmptyInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } controls: {
            HStack(spacing: 6) {
                if account.canTurnOff {
                    MeterSwitch(
                        label: "Track \(name ?? account.defaultName)",
                        isOn: Binding {
                            account.isEnabled
                        } set: {
                            setEnabled($0)
                        })
                }
                if account.isRemovable {
                    RemoveButton(name: name ?? account.defaultName, action: remove)
                }
            }
        }
        .opacity(account.isEnabled ? 1 : 0.7)
    }
}

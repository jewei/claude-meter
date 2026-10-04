import MeterApp
import MeterDomain
import SwiftUI

/// One Claude config dir: its name, folder, plan, and issue, with a tracking switch (not for
/// the default account) and Remove for folders that the user added.
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
                PathChip(path: account.path)
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
                if !account.isDefault {
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

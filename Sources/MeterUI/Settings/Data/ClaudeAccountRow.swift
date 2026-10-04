import MeterApp
import MeterDomain
import SwiftUI

/// One Claude login: its name, config dir, plan, and issue, with a tracking switch where the
/// login can be turned off and Remove for folders that the user added. A login that is not
/// tracked says so in a chip.
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
            id: account.id.rawValue, name: name, defaultName: account.defaultName,
            isTracked: account.isEnabled, rename: rename,
            remove: account.isRemovable ? remove : nil
        ) {
            HStack(spacing: 6) {
                if let path = account.path {
                    PathChip(path: path)
                } else {
                    Text("Active login, no config dir")
                        .font(MeterFont.body(11, .semibold))
                        .foregroundStyle(Palette.inkMuted)
                }
                switch PlanChoice(reported: account.reportedPlan, override: planOverride) {
                case .reported(let badge): PlanBadgeView(badge: badge)
                case .pickable(let current): PlanMenu(current: current, choose: setPlan)
                }
                if let chip = DataSourceText.trackingChip(isEnabled: account.isEnabled) {
                    ChipView(text: chip)
                }
            }
            if let issue = account.issue {
                Text(issue)
                    .font(MeterFont.body(11, .bold))
                    .foregroundStyle(Palette.energyEmptyInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } controls: {
            if account.canTurnOff {
                MeterSwitch(
                    label: "Track \(name ?? account.defaultName)",
                    isOn: Binding {
                        account.isEnabled
                    } set: {
                        setEnabled($0)
                    })
            }
        }
    }
}

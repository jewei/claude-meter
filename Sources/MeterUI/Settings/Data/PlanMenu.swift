import MeterApp
import SwiftUI

/// The plan badge of a Claude login with a menu to change it: "Set plan" while there is no
/// badge, then the badge. The plans, the reset item, and the tooltip come from ``PlanChoice``.
struct PlanMenu: View {
    let choice: PlanChoice
    let choose: (String?) -> Void

    var body: some View {
        Menu {
            ForEach(PlanChoice.plans, id: \.self) { plan in
                Button(plan) { choose(plan) }
            }
            if let reset = choice.resetTitle {
                Divider()
                Button(reset) { choose(nil) }
            }
        } label: {
            HStack(spacing: 4) {
                if let current = choice.current {
                    PlanBadgeView(badge: current)
                } else {
                    Text("Set plan")
                        .font(MeterFont.body(11, .bold))
                        .foregroundStyle(Palette.inkMuted)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(QuietButtonStyle(radius: 8))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(choice.current.map { "Plan \($0.text)" } ?? "Set plan")
        .help(choice.help)
    }
}

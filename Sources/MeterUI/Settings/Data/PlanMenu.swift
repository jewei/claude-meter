import MeterApp
import SwiftUI

/// A badge for a login that reports no plan: "Set plan" until the user picks one, then the
/// chosen plan with a menu to change or remove it. The plans come from ``PlanChoice``.
struct PlanMenu: View {
    let current: PlanBadge?
    let choose: (String?) -> Void

    var body: some View {
        Menu {
            ForEach(PlanChoice.plans, id: \.self) { plan in
                Button(plan) { choose(plan) }
            }
            if current != nil {
                Divider()
                Button("Remove plan") { choose(nil) }
            }
        } label: {
            HStack(spacing: 4) {
                if let current {
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
        .accessibilityLabel(current.map { "Plan \($0.text)" } ?? "Set plan")
        .help("This login reports no plan. Choose the badge to show.")
    }
}

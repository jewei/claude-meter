import MeterApp
import SwiftUI

/// A badge for a login that reports no plan: "Set plan" until the user picks one, then the
/// chosen plan with a menu to change or remove it.
struct PlanMenu: View {
    static let plans = ["Pro", "Max 5x", "Max 20x", "Team", "Enterprise", "Free"]

    let current: String?
    let choose: (String?) -> Void

    var body: some View {
        Menu {
            ForEach(Self.plans, id: \.self) { plan in
                Button(plan) { choose(plan) }
            }
            if current != nil {
                Divider()
                Button("Remove plan") { choose(nil) }
            }
        } label: {
            HStack(spacing: 4) {
                if let badge = PlanBadge(plan: current) {
                    PlanBadgeView(badge: badge)
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
        .accessibilityLabel(current.map { "Plan \($0)" } ?? "Set plan")
        .help("This login reports no plan. Choose the badge to show.")
    }
}

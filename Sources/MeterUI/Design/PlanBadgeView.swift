import MeterApp
import SwiftUI

/// A capsule with the plan name in its tier colors: violet for Max, green for Pro, gray for
/// Free.
struct PlanBadgeView: View {
    let badge: PlanBadge

    var body: some View {
        let colors = badge.tier.colors
        Text(badge.text)
            .font(MeterFont.display(10, .bold))
            .foregroundStyle(colors.foreground)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(colors.background))
            .help(badge.text)
            .accessibilityLabel("Plan \(badge.text)")
    }
}

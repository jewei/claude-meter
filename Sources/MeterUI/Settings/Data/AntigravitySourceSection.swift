import MeterApp
import SwiftUI

/// Antigravity's controls in Settings > Data: the plan badge picker.
struct AntigravitySourceSection: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Plan")
                .font(MeterFont.body(12, .semibold))
                .foregroundStyle(Palette.inkMuted)
            PlanMenu(
                choice: model.antigravityPlan,
                plans: PlanChoice.antigravityPlans,
                choose: { model.setAntigravityPlan($0) })
            Spacer(minLength: 0)
        }
    }
}

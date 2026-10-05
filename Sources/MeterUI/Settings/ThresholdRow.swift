import MeterApp
import SwiftUI

/// "Warning at 80%" with its slider.
struct ThresholdRow: View {
    let label: String
    let color: Color
    let ink: Color
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Circle().fill(color).frame(width: 12, height: 12)
                Text(label)
                    .font(MeterFont.display(16, .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                pill
            }
            .accessibilityHidden(true)
            ThresholdSlider(value: $value, range: range, step: step, color: color, label: label)
        }
    }

    /// The threshold in a capsule, as wide as `100%`, so the capsule keeps its size while the
    /// slider moves, and both rows show the same capsule.
    var pill: some View {
        Text(ThresholdText.percent(value, in: range))
            .font(MeterFont.display(14, .bold))
            .foregroundStyle(ink)
            .fixedNumberWidth(
                fitting: FixedNumberWidth.percent, font: MeterFont.display(14, .bold),
                alignment: .center
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

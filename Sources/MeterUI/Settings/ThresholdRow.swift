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
                Text("\(Int(ThresholdSlider.bounded(value, in: range).rounded()))%")
                    .font(MeterFont.display(14, .bold))
                    .foregroundStyle(ink)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(color.opacity(0.16)))
            }
            .accessibilityHidden(true)
            ThresholdSlider(value: $value, range: range, step: step, color: color, label: label)
        }
    }
}

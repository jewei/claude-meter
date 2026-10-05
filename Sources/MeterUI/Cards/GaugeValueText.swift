import MeterApp
import SwiftUI

/// A gauge's value: `78%` in the display face, or `—` in the body face one size smaller when
/// the window has no value, because the display face draws the dash like a minus sign.
///
/// The value is always as wide as `100%` in the display face, the widest value, so a new
/// value never moves the caption or the title beside it (``FixedNumberWidth``).
struct GaugeValueText: View {
    let gauge: GaugeModel
    let size: CGFloat
    let color: Color

    var body: some View {
        Text(gauge.valueText)
            .font(gauge.hasValue ? MeterFont.display(size, .bold) : MeterFont.body(size - 1, .bold))
            .foregroundStyle(color)
            .fixedNumberWidth(
                fitting: FixedNumberWidth.percent, font: MeterFont.display(size, .bold))
    }
}

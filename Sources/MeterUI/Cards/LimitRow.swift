import MeterApp
import SwiftUI

/// A further limit window on one line, such as Opus: dot, short title, value, and reset.
struct LimitRow: View {
    let gauge: GaugeModel

    var body: some View {
        HStack(spacing: 6) {
            EnergyDot(color: gauge.severity.fill)
            Text(gauge.shortTitle)
                .font(MeterFont.body(11, .bold))
                .foregroundStyle(Palette.ink)
            Text(gauge.valueText)
                .font(MeterFont.display(12, .bold))
                .foregroundStyle(gauge.severity.ink)
                .monospacedDigit()
            if let caption = gauge.caption {
                Text(caption)
                    .font(MeterFont.body(11, .semibold))
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 4)
            if let reset = gauge.resetText {
                Text(reset)
                    .font(MeterFont.body(11, .semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.title)
        .accessibilityValue(gauge.accessibilityValue)
    }
}

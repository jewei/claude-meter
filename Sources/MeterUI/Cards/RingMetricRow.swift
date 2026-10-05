import MeterApp
import SwiftUI

/// A ring card row: band dot, short title, value with its caption, and the reset below.
struct RingMetricRow: View {
    let gauge: GaugeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                EnergyDot(color: gauge.severity.fill)
                Text(gauge.shortTitle)
                    .font(MeterFont.body(11, .bold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                GaugeValueText(gauge: gauge, size: 14, color: gauge.severity.ink)
                if let caption = gauge.caption {
                    Text(caption)
                        .font(MeterFont.body(11, .semibold))
                        .foregroundStyle(Palette.inkMuted)
                }
            }
            if let reset = gauge.resetText {
                Text(reset)
                    .font(MeterFont.body(11, .semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 15)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.title)
        .accessibilityValue(gauge.accessibilityValue)
    }
}

import MeterApp
import SwiftUI

/// A share of usage, such as Cursor's Auto and API usage: title and value over a thin bar.
struct UsageBarRow: View {
    let gauge: GaugeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(gauge.title)
                    .font(MeterFont.body(11, .semibold))
                    .foregroundStyle(Palette.inkMuted)
                Spacer(minLength: 4)
                Text(gauge.valueWithCaption)
                    .font(MeterFont.body(11, .bold))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
            }
            EnergyBar(fraction: gauge.fraction, color: gauge.severity.fill, height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.title)
        .accessibilityValue(gauge.accessibilityValue)
    }
}

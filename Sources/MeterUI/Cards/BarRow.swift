import MeterApp
import SwiftUI

/// One window as a 12 pt energy bar, with "Session · 60% left" and the reset below it when
/// the card's caption does not state them already.
struct BarRow: View {
    let gauge: GaugeModel
    var showsLabels = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EnergyBar(fraction: gauge.fraction, color: gauge.severity.fill, height: 12)
            if showsLabels {
                HStack(spacing: 6) {
                    Text(gauge.summaryText)
                    Spacer(minLength: 4)
                    if let reset = gauge.resetText { Text(reset) }
                }
                .font(MeterFont.body(11, .semibold))
                .foregroundStyle(Palette.inkMuted)
                .monospacedDigit()
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.title)
        .accessibilityValue(gauge.accessibilityValue)
    }
}

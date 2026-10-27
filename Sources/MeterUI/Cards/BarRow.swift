import MeterApp
import SwiftUI

/// One window as a 14 pt energy bar, with "Session · 60% left" and the reset below it when
/// the card's caption does not state them already. The pace has its own line, also on cards
/// whose caption states the rest. The bar hatches the shortfall when the model gives it one
/// (``GaugeModel/shortfallSeverity``).
struct BarRow: View {
    let gauge: GaugeModel
    var showsLabels = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            EnergyBar(
                fraction: gauge.fraction, color: gauge.severity.fill, height: 14,
                mark: gauge.evenPaceFraction, shortfall: gauge.shortfallSeverity?.fill,
                outline: gauge.severity.trackOutline)
            if showsLabels {
                HStack(spacing: 8) {
                    Text(gauge.summaryText)
                    Spacer(minLength: 4)
                    if let reset = gauge.resetText { Text(reset) }
                }
                .font(MeterFont.body(11, .semibold))
                .foregroundStyle(Palette.inkMuted)
                .monospacedDigit()
                .lineLimit(1)
            }
            if let pace = gauge.paceText { PaceLine(text: pace, severity: gauge.paceSeverity) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.title)
        .accessibilityValue(gauge.accessibilityValue)
    }
}

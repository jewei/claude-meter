import MeterApp
import SwiftUI

/// A further limit window on one line, such as Opus: dot, short title, value, and reset. The
/// pace has its own line below, so the first line is not clipped.
struct LimitRow: View {
    let gauge: GaugeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            line
            if let pace = gauge.paceText {
                PaceLine(text: pace, severity: gauge.paceSeverity)
                    .padding(.leading, 15)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.title)
        .accessibilityValue(gauge.accessibilityValue)
    }

    private var line: some View {
        HStack(spacing: 6) {
            EnergyDot(color: gauge.severity.fill)
            Text(gauge.shortTitle)
                .font(MeterFont.body(11, .bold))
                .foregroundStyle(Palette.ink)
            GaugeValueText(gauge: gauge, size: 12, color: gauge.severity.ink)
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
    }
}

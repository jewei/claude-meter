import MeterDomain
import SwiftUI

/// `Runs out in 2h 10m` under a limit. A pace with a severity runs out before the reset: it
/// takes a warning icon and that severity's ink. Otherwise it is in the style of the reset
/// text.
struct PaceLine: View {
    let text: String
    var severity: Severity? = nil

    var body: some View {
        if let severity {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text(text)
                    .font(MeterFont.body(11, .bold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(severity.ink)
        } else {
            Text(text)
                .font(MeterFont.body(11, .semibold))
                .foregroundStyle(Palette.inkMuted)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

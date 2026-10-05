import MeterApp
import SwiftUI

/// "ACCOUNTS", an info icon with the drag hint when it applies, and the ring legend in ring
/// style.
struct AccountsHeader: View {
    let legend: RingLegendModel?
    let dragHint: String?

    var body: some View {
        HStack(spacing: 5) {
            Text("ACCOUNTS")
                .font(MeterFont.body(11, .extraBold))
                .tracking(0.99)
                .foregroundStyle(Palette.sectionLabel)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("Accounts")
            if let dragHint {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .contentShape(Rectangle())
                    .help(dragHint)
                    .accessibilityLabel(dragHint)
            }
            Spacer()
            if let legend { RingLegend(legend: legend) }
        }
        .padding(.horizontal, 2)
    }
}

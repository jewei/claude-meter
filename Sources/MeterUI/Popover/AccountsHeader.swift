import SwiftUI

/// "ACCOUNTS", the ring legend in ring style, and the drag hint when it applies.
struct AccountsHeader: View {
    let showsLegend: Bool
    let dragHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("ACCOUNTS")
                    .font(MeterFont.body(11, .extraBold))
                    .tracking(0.99)
                    .foregroundStyle(Palette.sectionLabel)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("Accounts")
                Spacer()
                if showsLegend { RingLegend() }
            }
            if let dragHint {
                Text(dragHint)
                    .font(MeterFont.body(11, .semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 2)
    }
}

import SwiftUI

/// The key beside the "ACCOUNTS" label in ring style: an outline dot for weekly and a filled
/// dot for the 5-hour session.
struct RingLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle().strokeBorder(Palette.inkMuted, lineWidth: 2.5).frame(width: 9, height: 9)
                Text("weekly")
            }
            HStack(spacing: 4) {
                Circle().fill(Palette.inkMuted).frame(width: 9, height: 9)
                Text("5-hour")
            }
        }
        .font(MeterFont.body(10, .bold))
        .foregroundStyle(Palette.inkMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Outer ring weekly, inner ring 5-hour")
    }
}

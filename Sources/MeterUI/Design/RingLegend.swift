import MeterApp
import SwiftUI

/// The key beside the "ACCOUNTS" label in ring style: an outline dot for the weekly outer
/// ring and a filled dot for the session inner ring, named with the rows' own short titles.
struct RingLegend: View {
    let legend: RingLegendModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle().strokeBorder(Palette.inkMuted, lineWidth: 2.5).frame(width: 9, height: 9)
                Text(legend.outer)
            }
            HStack(spacing: 4) {
                Circle().fill(Palette.inkMuted).frame(width: 9, height: 9)
                Text(legend.inner)
            }
        }
        .font(MeterFont.body(10, .bold))
        .foregroundStyle(Palette.inkMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(legend.accessibilityLabel)
    }
}

import SwiftUI

/// The 9 pt rounded-square pip beside a metric row.
struct EnergyDot: View {
    var color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

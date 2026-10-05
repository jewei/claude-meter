import MeterApp
import SwiftUI

/// One sign-in state with an icon: a check when signed in, a warning for a problem, and a
/// neutral circle otherwise.
struct SignInStatusLine: View {
    let status: DataSourceText.Status
    var label: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            if let label {
                Text(label)
                    .font(MeterFont.body(12, .bold))
                    .foregroundStyle(Palette.ink)
            }
            Text(status.text)
                .font(MeterFont.body(12, .semibold))
                .foregroundStyle(status.isProblem ? Palette.energyLowInk : Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if status.isSignedIn { return "checkmark.circle.fill" }
        return status.isProblem ? "exclamationmark.triangle.fill" : "circle.dashed"
    }

    private var tint: Color {
        if status.isSignedIn { return Palette.heroFull.ink }
        return status.isProblem ? Palette.energyLowInk : Palette.inkMuted
    }
}

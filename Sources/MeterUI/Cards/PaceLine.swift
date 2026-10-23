import SwiftUI

/// `Runs out in 2h 10m` under a limit row, in the style of the reset text.
struct PaceLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(MeterFont.body(11, .semibold))
            .foregroundStyle(Palette.inkMuted)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
}

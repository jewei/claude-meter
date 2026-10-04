import MeterApp
import SwiftUI

/// A card's own status: a failure in the warning ink, other news in muted ink.
struct StatusLineView: View {
    let status: StatusLine

    var body: some View {
        Text(status.text)
            .font(MeterFont.body(11, .semibold))
            .foregroundStyle(status.isFailure ? Palette.energyLowInk : Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

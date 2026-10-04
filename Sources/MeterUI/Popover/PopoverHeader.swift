import MeterApp
import SwiftUI

/// The bolt tile, the app name, the updated time, and the Settings and Quit buttons.
///
/// The updated time is the only part that may shrink: it truncates first, so the buttons
/// always stay visible at 360 pt.
struct PopoverHeader: View {
    let popover: PopoverModel
    let model: AppModel
    let actions: PopoverActions

    var body: some View {
        HStack(spacing: 9) {
            RaisedTile(
                symbol: "bolt.fill", fill: Palette.energyFull, size: 30, radius: 9, glyphSize: 14)
            Text("Claude Meter")
                .font(MeterFont.display(18, .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            if let updated = popover.updatedText {
                Text(updated)
                    .font(MeterFont.body(11, .semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .help("Last updated")
                    .accessibilityLabel("Last updated \(updated)")
            }
            SquareIconButton(symbol: "gearshape.fill", label: "Settings") {
                model.completeOnboarding()
                actions.openSettings()
            }
            if popover.showsQuit {
                SquareIconButton(symbol: "power", label: "Quit Claude Meter", action: actions.quit)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

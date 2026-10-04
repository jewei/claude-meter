import MeterApp
import SwiftUI

/// A question in the page, in place of the control that asked it: a title, what will be
/// lost, Cancel, and a red button. Escape cancels. Nothing blocks the app or the window.
struct InlineConfirmation: View {
    let confirmation: DataSourceText.Confirmation
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.energyEmptyInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(confirmation.title)
                        .font(MeterFont.display(15, .semibold))
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(confirmation.message)
                        .font(MeterFont.body(12, .semibold))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(action: cancel) {
                    ChunkyButtonLabel(title: "Cancel")
                }
                .buttonStyle(.chunky)
                .keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle, action: confirm)
                    .buttonStyle(
                        RaisedButtonStyle(
                            fill: Palette.destructive, shadow: Palette.destructiveShadow)
                    )
                    .fixedSize()
            }
        }
        .padding(12)
        .background(shape.fill(Palette.popover))
        .overlay(shape.strokeBorder(Palette.energyEmptyInk.opacity(0.4), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }
}

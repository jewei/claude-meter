import MeterApp
import SwiftUI

/// A message above the hero: a top-aligned icon and wrapping text on a lightly tinted fill
/// with a 1 pt border, so multiline errors stay easy to scan.
struct NoticeBanner: View {
    let text: String
    let systemImage: String
    let tint: Color
    /// The text color when the tint is too light for small text on the tinted fill.
    var textColor: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(MeterFont.body(11, .semibold))
                .monospacedDigit()
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(textColor ?? tint)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(shape.fill(tint.opacity(0.08)))
        .overlay(shape.strokeBorder(tint.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

extension NoticeBanner {
    /// A notice from the popover model. Actions and failures use the warning ink; old data
    /// uses muted ink.
    init(_ notice: Notice) {
        switch notice.kind {
        case .action:
            self.init(text: notice.text, systemImage: "key.slash.fill", tint: Palette.energyLowInk)
        case .warning:
            self.init(
                text: notice.text, systemImage: "exclamationmark.triangle.fill",
                tint: Palette.energyLowInk)
        case .info:
            self.init(text: notice.text, systemImage: "clock.fill", tint: Palette.inkMuted)
        }
    }
}

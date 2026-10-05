import MeterApp
import SwiftUI

/// A visual choice between ring and bar cards, with a checkmark on the selected one.
struct CardStyleOption: View {
    let style: AppearanceSettings.CardStyle
    let isSelected: Bool
    let select: () -> Void

    private var title: String {
        switch style {
        case .rings: "Rings"
        case .bars: "Energy bars"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        Button(action: select) {
            VStack(spacing: 8) {
                preview.frame(height: 58).accessibilityHidden(true)
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(title).font(MeterFont.display(13, .semibold))
                }
                .foregroundStyle(isSelected ? Palette.heroFull.ink : Palette.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(
                shape.strokeBorder(
                    isSelected ? Palette.heroFull.border : Palette.cardBorder,
                    lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(
            QuietButtonStyle(
                radius: 13,
                surface: .fill(isSelected ? Palette.heroFull.background : Palette.popover))
        )
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        switch style {
        case .rings:
            ActivityRings(
                outer: .init(fraction: 0.64, color: Palette.energyFull),
                inner: .init(fraction: 0.82, color: Palette.energyFull), letter: "", size: 58)
        case .bars:
            VStack(spacing: 10) {
                EnergyBar(fraction: 0.82, color: Palette.energyFull, height: 9)
                EnergyBar(fraction: 0.64, color: Palette.energyFull, height: 9)
            }
            .frame(width: 100)
        }
    }
}

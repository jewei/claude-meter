import SwiftUI

/// A row of equal-width options, one selected, such as "5h / 7d / Both".
struct ChoiceRow<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection == option.value
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(MeterFont.display(13, .semibold))
                        .foregroundStyle(isSelected ? Palette.heroFull.ink : Palette.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .overlay(
                            shape.strokeBorder(
                                isSelected ? Palette.heroFull.border : Palette.cardBorder,
                                lineWidth: 1.5))
                }
                .buttonStyle(
                    QuietButtonStyle(
                        radius: 12,
                        surface: .fill(
                            isSelected ? Palette.heroFull.background : Palette.popover))
                )
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

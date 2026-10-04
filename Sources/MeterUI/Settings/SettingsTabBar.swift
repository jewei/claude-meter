import SwiftUI

/// The centered row of tab buttons. The selected tab has a tinted fill and border, and
/// VoiceOver hears it as selected.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                button(for: tab)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings tabs")
    }

    private func button(for tab: SettingsTab) -> some View {
        let isSelected = selection == tab
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(height: 20)
                Text(tab.title).font(MeterFont.body(12, .extraBold))
            }
            .foregroundStyle(isSelected ? Palette.heroFull.ink : Palette.inkMuted)
            .frame(width: 112)
            .padding(.vertical, 10)
            .background(shape.fill(isSelected ? Palette.heroFull.background : .clear))
            .overlay(
                shape.strokeBorder(isSelected ? Palette.heroFull.border : .clear, lineWidth: 1.5))
        }
        .buttonStyle(QuietButtonStyle(radius: 14))
        .keyboardShortcut(tab.shortcut, modifiers: .command)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(tab.title) (⌘\(tab.rawValue + 1))")
    }
}

import MeterApp
import SwiftUI

/// The Settings window content: the tab bar over the selected page.
struct SettingsView: View {
    static let size = CGSize(width: 580, height: 700)

    let model: AppModel
    @State var selection = SettingsTab.data

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
            Rectangle().fill(Palette.popoverBorder).frame(height: 1)
            page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Self.size.width)
        .frame(minHeight: Self.size.height, alignment: .top)
        .background(Palette.popover)
        .tint(Palette.accent)
    }

    @ViewBuilder private var page: some View {
        switch selection {
        case .data: DataSettingsView(model: model)
        case .appearance: AppearanceSettingsView(model: model)
        case .advanced: AdvancedSettingsView(model: model)
        case .about: AboutSettingsView()
        }
    }
}

import MeterApp
import SwiftUI

/// The Settings window content: the tab bar over the selected page.
struct SettingsView: View {
    /// The width, and the height that the window opens with when the screen allows it.
    static let size = CGSize(width: 580, height: 700)
    /// The shortest the window can be made. Pages scroll.
    static let minimumHeight: CGFloat = 420

    let model: AppModel
    @Bindable var navigation: SettingsNavigation
    /// Only the newest inline question or token form answers Escape.
    @State private var cancelShortcuts = CancelShortcuts()

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $navigation.tab)
            Rectangle().fill(Palette.popoverBorder).frame(height: 1)
            page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Self.size.width)
        .frame(minHeight: Self.minimumHeight, alignment: .top)
        .background(Palette.popover)
        .tint(Palette.accent)
        .environment(\.cancelShortcuts, cancelShortcuts)
    }

    @ViewBuilder private var page: some View {
        switch navigation.tab {
        case .data: DataSettingsView(model: model)
        case .appearance: AppearanceSettingsView(model: model)
        case .advanced: AdvancedSettingsView(model: model)
        case .about: AboutSettingsView()
        }
    }
}

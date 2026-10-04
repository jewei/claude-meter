import MeterApp
import SwiftUI

/// Everything below the header: the update notice, then loading, a status screen, or the
/// accounts.
struct PopoverBody: View {
    let popover: PopoverModel
    let model: AppModel
    let actions: PopoverActions

    var body: some View {
        VStack(spacing: 0) {
            if popover.showsUpdateNotice {
                Button {
                    actions.checkForUpdates()
                } label: {
                    // Green text on the green tint is below 4.5:1 in light mode; the text
                    // stays ink and the icon carries the color.
                    NoticeBanner(
                        text: "Update available — click to install",
                        systemImage: "arrow.down.circle.fill", tint: Palette.energyFullInk,
                        textColor: Palette.ink)
                }
                .buttonStyle(QuietButtonStyle(radius: 12))
                .padding(.horizontal, 15)
                .padding(.bottom, 10)
            }
            switch popover.content {
            case .loading(let message):
                LoadingView(message: message)
            case .status(let screen):
                StatusScreenView(screen: screen) {
                    switch screen.action {
                    // The welcome asks for a data source, so it opens on Data.
                    case .getStarted: actions.openSettings(.data)
                    case .openSettings: actions.openSettings(nil)
                    }
                }
            case .accounts(let accounts):
                AccountsView(accounts: accounts, model: model)
                    .padding(.horizontal, 15)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
            }
        }
    }
}

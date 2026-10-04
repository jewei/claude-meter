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
                    NoticeBanner(
                        text: "Update available — click to install",
                        systemImage: "arrow.down.circle.fill", tint: Palette.energyFullInk)
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
                    model.completeOnboarding()
                    actions.openSettings()
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

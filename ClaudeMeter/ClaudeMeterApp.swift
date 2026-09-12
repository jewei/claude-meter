import ClaudeMeterCore
import SwiftUI

@main
struct ClaudeMeterApp: App {
    @NSApplicationDelegateAdaptor(ClaudeMeterAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(appState)
                .frame(width: 360)
                .onAppear { appState.popoverDidOpen() }
                .onDisappear { appState.popoverDidClose() }
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        // A separate window, not a popover section: 30 daily bars do not fit the
        // 360-point popover. `.windowResizability(.contentMinSize)` keeps the user
        // free to widen it without letting it collapse below the chart.
        Window("Usage & Spend", id: AppState.usageSpendWindowID) {
            UsageSpendView()
                .environmentObject(appState)
        }
        .windowResizability(.contentMinSize)
    }
}

import ClaudeMeterCore
import SwiftUI

@main
struct ClaudeMeterApp: App {
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
    }
}

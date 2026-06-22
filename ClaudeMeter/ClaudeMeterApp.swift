import SwiftUI
import ClaudeMeterCore

@main
struct ClaudeMeterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(appState)
                .frame(width: 320)
                .onAppear { appState.isPopoverOpen = true }
                .onDisappear { appState.isPopoverOpen = false }
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}

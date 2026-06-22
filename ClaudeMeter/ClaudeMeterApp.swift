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

        Window("Mini Monitor", id: "mini-monitor") {
            MiniMonitorView()
                .environmentObject(appState)
        }
        .defaultSize(width: 240, height: 64)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

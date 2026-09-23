import AppKit
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

final class ClaudeMeterAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: MeterSettings.fileLoggingEnabledKey) {
            MeterLog.setFileLoggingEnabled(true)
        }
    }

}

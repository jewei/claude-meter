import AppKit
import ClaudeMeterCore
import Darwin
import SwiftUI

@main
struct ClaudeMeterApp: App {
    @NSApplicationDelegateAdaptor(ClaudeMeterAppDelegate.self) private var appDelegate
    @StateObject private var appState =
        isTestHost
        ? AppState(usageStore: UsageStore(providers: [])) : AppState()

    /// Hosted tests and the opt-in benchmark must not start live provider work.
    static let isTestHost: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["CLAUDE_METER_MEASURE_PRESENTATION"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
        {
            return true
        }
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let name = String(cString: raw)
            if name.hasSuffix("/XCTest") || name.hasSuffix("/Testing") { return true }
        }
        return false
    }()

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
        guard !ClaudeMeterApp.isTestHost else { return }
        if UserDefaults.standard.bool(forKey: MeterSettings.fileLoggingEnabledKey) {
            MeterLog.setFileLoggingEnabled(true)
        }
    }

}

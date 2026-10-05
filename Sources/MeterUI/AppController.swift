import AppKit
import MeterApp

/// Wires the app at launch: fonts, the model, the status item, the popover, Settings, and the
/// menu bar shown while Settings is open.
///
/// `AppModel.live` restores the saved readings, applies the log-file setting at launch and
/// on each change, and starts refreshing.
@MainActor final class AppController: NSObject, NSApplicationDelegate {
    private let updater: any Updater
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var popover: PopoverPanelController?
    private var settingsWindow: SettingsWindowController?

    init(updater: any Updater) {
        self.updater = updater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MeterFont.registerBundledFonts()
        let menu = MainMenu.make(target: self)
        NSApp.mainMenu = menu.main
        NSApp.windowsMenu = menu.window

        let model = AppModel.live(updater: updater)
        let statusItem = StatusItemController(model: model)
        let popover = PopoverPanelController(model: model) { [weak statusItem] in
            statusItem?.button
        }
        let settingsWindow = SettingsWindowController(model: model)

        statusItem.onClick = { [weak popover] in popover?.toggle() }
        popover.onVisibilityChange = { [weak statusItem] isVisible in
            statusItem?.setHighlighted(isVisible)
        }
        popover.onOpenSettings = { [weak self] tab in self?.openSettings(tab: tab) }

        self.model = model
        self.statusItem = statusItem
        self.popover = popover
        self.settingsWindow = settingsWindow
    }

    /// Opening the app again from Finder or Spotlight shows Settings, since there is no
    /// other window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings(nil)
        return false
    }

    /// Command-comma and Settings… in the app menu.
    @objc func openSettings(_ sender: Any?) {
        openSettings(tab: nil)
    }

    /// About Claude Meter in the app menu.
    @objc func openAbout(_ sender: Any?) {
        openSettings(tab: .about)
    }

    /// Closes the popover and brings Settings to the front. Every path into Settings ends
    /// the welcome, so the "Fetch usage" switch there is true: refreshing starts.
    private func openSettings(tab: SettingsTab?) {
        model?.completeOnboarding()
        popover?.close()
        settingsWindow?.show(tab: tab)
    }
}

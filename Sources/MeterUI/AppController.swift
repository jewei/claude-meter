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
        NSApp.mainMenu = MainMenu.make(settingsTarget: self)

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
        popover.onOpenSettings = { [weak self] in self?.openSettings(nil) }

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

    /// Closes the popover and brings Settings to the front.
    @objc func openSettings(_ sender: Any?) {
        popover?.close()
        settingsWindow?.show()
    }
}

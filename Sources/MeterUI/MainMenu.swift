import AppKit

/// The menu bar that shows while Settings is open: the app menu, Edit (so copy and paste work
/// in text fields), and Window. The app installs it once at launch; macOS shows it only
/// while the app is regular.
@MainActor enum MainMenu {
    /// - Parameter target: receives `openSettings(_:)` for Command-comma and `openAbout(_:)`.
    /// - Returns: the main menu, and the Window menu for `NSApplication.windowsMenu`.
    static func make(target: AppController) -> (main: NSMenu, window: NSMenu) {
        let main = NSMenu()
        let window = windowMenu()
        main.addItem(submenu(appMenu(target: target)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(window))
        return (main, window)
    }

    private static func appMenu(target: AppController) -> NSMenu {
        let menu = NSMenu(title: "Claude Meter")
        let about = menu.addItem(
            withTitle: "About Claude Meter", action: #selector(AppController.openAbout(_:)),
            keyEquivalent: "")
        about.target = target
        menu.addItem(.separator())
        let settings = menu.addItem(
            withTitle: "Settings…", action: #selector(AppController.openSettings(_:)),
            keyEquivalent: ",")
        settings.target = target
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide Claude Meter", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let others = menu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Claude Meter", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        menu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

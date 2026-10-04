import AppKit
import MeterApp
import SwiftUI

/// Owns the Settings window, an ordinary titled window that the app creates once.
///
/// While it is open the app uses the regular activation policy, so it has a Dock icon, a
/// menu bar, and Command-Tab, and comes to the front like any app. When it closes the app
/// goes back to an accessory with no Dock icon.
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let title = "Claude Meter Settings"

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        NSApp.setActivationPolicy(.regular)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.size),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = Self.title
        window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.popoverBackground
        let content = NSHostingView(rootView: SettingsView(model: model))
        // The window keeps its fixed size; pages scroll instead of growing it.
        content.sizingOptions = []
        window.contentView = content
        window.delegate = self
        self.window = window
        return window
    }
}

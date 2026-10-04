import AppKit
import MeterApp
import SwiftUI

/// Owns the Settings window, an ordinary titled window that the app creates once.
///
/// While it is open the app uses the regular activation policy, so it has a Dock icon, a
/// menu bar, and Command-Tab, and it comes to the front like any app. The app goes back to an
/// accessory with no Dock icon when the last titled window closes, so Sparkle's update window
/// or the About panel keeps the Dock icon after Settings closes.
///
/// The window is resizable in height and never taller than the screen; pages scroll. It
/// remembers its place. While it is closed, its SwiftUI content is gone, so nothing renders.
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let title = "Claude Meter Settings"
    static let frameName = "ClaudeMeterSettings"

    private let model: AppModel
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    private var observers: [any NSObjectProtocol] = []

    init(model: AppModel) {
        self.model = model
        super.init()
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { note in
                let closing = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated { Self.windowWillClose(closing) }
            })
    }

    /// Shows Settings in front, on `tab` when given, else on the tab that the user left.
    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        let window = self.window ?? makeWindow()
        if window.contentView == nil { window.contentView = makeContent() }
        // The policy changes first: an accessory app cannot come to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if !window.isVisible { place(window) }
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14 and can lag behind the policy change.
        // Ask once more on the next turn of the main loop.
        Task { @MainActor [weak window] in
            guard !NSApp.isActive, let window, window.isVisible else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Drops the SwiftUI content, so a closed window does not keep rendering on every
    /// settings change. The selected tab stays in ``navigation``.
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = Self.title
        window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.popoverBackground
        window.contentMinSize = NSSize(
            width: SettingsView.size.width, height: SettingsView.minimumHeight)
        window.contentMaxSize = NSSize(
            width: SettingsView.size.width, height: .greatestFiniteMagnitude)
        window.collectionBehavior.insert(.fullScreenNone)
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        self.window = window
        return window
    }

    private func makeContent() -> NSView {
        let content = NSHostingView(rootView: SettingsView(model: model, navigation: navigation))
        // The window owns the size; pages scroll instead of growing it.
        content.sizingOptions = []
        return content
    }

    /// Keeps the window inside the visible frame of its screen, so the bottom of each page
    /// can be reached on a short screen.
    private func place(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = SettingsWindowPlacement.fitted(window.frame, in: visible)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    /// Returns the app to an accessory when the last titled window closes.
    private static func windowWillClose(_ closing: ObjectIdentifier?) {
        let windows = NSApp.windows.map { window in
            SettingsWindowPlacement.Window(
                isTitled: window.styleMask.contains(.titled),
                isOpen: window.isVisible || window.isMiniaturized,
                isClosing: ObjectIdentifier(window) == closing)
        }
        guard NSApp.activationPolicy() == .regular,
            !SettingsWindowPlacement.keepsDockIcon(windows)
        else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

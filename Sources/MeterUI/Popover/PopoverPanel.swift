import AppKit

/// The borderless window behind the popover. SwiftUI draws the rounded chrome; this window is
/// clear and casts the shadow.
///
/// It can become key without activating the app, so Escape reaches it and the user's app
/// keeps its focus. Because the app stays inactive, the panel allows tooltips while the app is
/// inactive; without that, no `.help` text in the popover would show.
final class PopoverPanel: NSPanel {
    /// Called for Escape, Command-period, and Command-W.
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        allowsToolTipsWhenApplicationIsInactive = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityLabel("Claude Meter")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Command-W closes the popover. A borderless window has no close button, so the
    /// standard implementation only beeps.
    override func performClose(_ sender: Any?) {
        onCancel?()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)) { return true }
        return super.validateMenuItem(menuItem)
    }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape. Some first responders do not forward it as `cancelOperation`.
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Keys that nothing in the popover handles, such as letters, do nothing instead of
    /// beeping.
    override func noResponder(for eventSelector: Selector) {
        guard eventSelector != #selector(NSResponder.keyDown(with:)) else { return }
        super.noResponder(for: eventSelector)
    }
}

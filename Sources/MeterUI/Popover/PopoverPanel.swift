import AppKit

/// The borderless window behind the popover. SwiftUI draws the rounded chrome; this window is
/// clear and casts the shadow.
///
/// It can become key without activating the app, so Escape reaches it and the user's app
/// keeps its focus.
final class PopoverPanel: NSPanel {
    /// Called for Escape and Command-period.
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
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityLabel("Claude Meter")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape. Some first responders do not forward it as `cancelOperation`.
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

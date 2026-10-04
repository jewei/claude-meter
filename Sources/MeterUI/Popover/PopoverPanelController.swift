import AppKit
import MeterApp
import SwiftUI

/// Shows ``PopoverView`` in a ``PopoverPanel`` under the status button.
///
/// The panel closes on a second click of the button, Escape, a click outside, app
/// deactivation, and when Settings opens. Its height follows the content: a change animates
/// with the top edge fixed, using the card disclosure curve, and applies at once under
/// Reduce Motion, while hidden, and just after opening.
@MainActor final class PopoverPanelController {
    /// Changes in the first moments after opening are the content settling, not a card
    /// opening, so they apply without animation.
    static let settleInterval: TimeInterval = 0.25
    /// Height changes smaller than this are measurement noise.
    static let tolerance: CGFloat = 0.5

    var onOpenSettings: () -> Void = {}
    var onVisibilityChange: (Bool) -> Void = { _ in }

    private let model: AppModel
    private let anchor: () -> NSStatusBarButton?
    private let panel = PopoverPanel()
    private let presentation = PopoverPresentation()
    private let hostingView: NSHostingView<PopoverView>
    private var headerHeight: CGFloat = 56
    private var contentHeight: CGFloat = PanelLayout.minimumBodyHeight
    private var openedAt = Date.distantPast
    private var monitors: [Any] = []
    private var observers: [any NSObjectProtocol] = []

    /// - Parameter anchor: the status button that the panel opens under.
    init(model: AppModel, anchor: @escaping () -> NSStatusBarButton?) {
        self.model = model
        self.anchor = anchor
        hostingView = NSHostingView(rootView: PopoverView(model: model, presentation: presentation))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.onCancel = { [weak self] in self?.close() }
        hostingView.rootView = PopoverView(
            model: model, presentation: presentation, actions: makeActions())
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        observers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFrame(animated: false) }
            })
    }

    var isShown: Bool { presentation.isVisible }

    func toggle() {
        isShown ? close() : show()
    }

    func show() {
        guard !presentation.isVisible else { return }
        presentation.isVisible = true
        openedAt = Date()
        model.popoverDidOpen()
        // Lay out now, so the first frame uses fresh heights.
        hostingView.layoutSubtreeIfNeeded()
        updateFrame(animated: false)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        onVisibilityChange(true)
    }

    func close() {
        guard presentation.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        presentation.isVisible = false
        model.popoverDidClose()
        onVisibilityChange(false)
    }

    // MARK: - Size and place

    private func makeActions() -> PopoverActions {
        PopoverActions(
            openSettings: { [weak self] in self?.onOpenSettings() },
            quit: { NSApplication.shared.terminate(nil) },
            headerHeightChanged: { [weak self] height in
                self?.measured(header: height)
            },
            contentHeightChanged: { [weak self] height in
                self?.measured(content: height)
            })
    }

    private func measured(header: CGFloat? = nil, content: CGFloat? = nil) {
        if let header, header.isFinite, abs(header - headerHeight) >= Self.tolerance {
            headerHeight = header
        } else if let content, content.isFinite, abs(content - contentHeight) >= Self.tolerance {
            contentHeight = content
        } else {
            return
        }
        let settled = Date().timeIntervalSince(openedAt) > Self.settleInterval
        updateFrame(animated: presentation.isVisible && settled)
    }

    private func updateFrame(animated: Bool) {
        let (anchorFrame, visibleFrame) = placement()
        let layout = PanelLayout(
            header: headerHeight, content: contentHeight, anchor: anchorFrame,
            visibleFrame: visibleFrame)
        if presentation.scrolls != layout.scrolls { presentation.scrolls = layout.scrolls }
        let frame = layout.frame
        guard !Self.isClose(frame, panel.frame) else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated, panel.isVisible, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.disclosureDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak panel] in
                MainActor.assumeIsolated { panel?.invalidateShadow() }
            }
        } else {
            panel.setFrame(frame, display: panel.isVisible)
            panel.invalidateShadow()
        }
    }

    /// The status button's frame and its screen's visible frame, in screen coordinates.
    private func placement() -> (anchor: CGRect, visibleFrame: CGRect) {
        if let button = anchor(), let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = window.screen ?? NSScreen.main
            return (frame, screen?.visibleFrame ?? Self.fallbackScreen)
        }
        let visible = NSScreen.main?.visibleFrame ?? Self.fallbackScreen
        return (CGRect(x: visible.maxX - 40, y: visible.maxY, width: 0, height: 0), visible)
    }

    private static let fallbackScreen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    private static func isClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < tolerance && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance
    }

    // MARK: - Clicks outside

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps, including their menu bar items.
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        {
            monitors.append(global)
        }
        // Clicks in this app's other windows. The status button toggles by itself.
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                let window = event.windowNumber
                MainActor.assumeIsolated { self?.localClick(inWindow: window) }
                return event
            })
        {
            monitors.append(local)
        }
    }

    private func localClick(inWindow number: Int) {
        guard number != panel.windowNumber, number != anchor()?.window?.windowNumber else {
            return
        }
        close()
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}

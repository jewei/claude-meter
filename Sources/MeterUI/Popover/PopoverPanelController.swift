import AppKit
import MeterApp
import SwiftUI

/// Shows ``PopoverView`` in a ``PopoverPanel`` under the status button.
///
/// The panel closes on a second click of the button, Escape, Command-W, a click outside, and
/// when the user leaves it: another app activates, the Space changes, the app hides or
/// resigns active, another window takes the keyboard, or Settings opens
/// (``PopoverDismissal``). Its height follows the content: a change animates with the top
/// edge fixed, using the card disclosure curve, and applies at once under Reduce Motion,
/// while hidden, and just after opening.
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
    /// System uptime of the last close that the user did not ask for.
    private var lastAutomaticClose: TimeInterval?
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
        observeChanges()
    }

    var isShown: Bool { presentation.isVisible }

    /// Opens or closes the popover for a click on the status button.
    func toggle() {
        let now = ProcessInfo.processInfo.systemUptime
        switch PopoverDismissal.toggle(
            isShown: isShown, now: now, lastAutomaticClose: lastAutomaticClose)
        {
        case .open: show()
        case .close: close()
        case .ignore: break
        }
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
        close(automatic: false)
    }

    /// Hides the panel, which also stops its clock. The state changes first, so the focus
    /// change that ordering out causes finds the popover closed already.
    private func close(automatic: Bool) {
        guard presentation.isVisible else { return }
        presentation.isVisible = false
        if automatic { lastAutomaticClose = ProcessInfo.processInfo.systemUptime }
        removeMonitors()
        panel.orderOut(nil)
        model.popoverDidClose()
        onVisibilityChange(false)
    }

    // MARK: - Size and place

    private func makeActions() -> PopoverActions {
        PopoverActions(
            openSettings: { [weak self] in self?.onOpenSettings() },
            checkForUpdates: { [weak self] in
                // Sparkle's window opens in front; the panel must not cover it.
                self?.close()
                self?.model.updater.checkForUpdates()
            },
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

    // MARK: - Leaving the popover

    private func observeChanges() {
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        observe(app, NSApplication.didResignActiveNotification) { _ in .appResignedActive }
        observe(app, NSApplication.didHideNotification) { _ in .appHidden }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { _ in .spaceChanged }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { activated in
            activated == ownProcess ? nil : .otherAppActivated
        }
        observe(app, NSWindow.didResignKeyNotification, object: panel) { [weak panel] _ in
            guard let key = NSApp.keyWindow else { return .panelResignedKey(toChildWindow: false) }
            return .panelResignedKey(toChildWindow: key.parent != nil && key.parent === panel)
        }
        observers.append(
            app.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFrame(animated: false) }
            })
    }

    /// Closes the open popover when `change` names a change that closes it. The closure gets
    /// the process ID of the app that the notification names, if any.
    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
        change: @escaping @MainActor (pid_t?) -> PopoverDismissal.Change?
    ) {
        observers.append(
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                let app =
                    note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self, self.isShown, let change = change(pid),
                        PopoverDismissal.closes(for: change)
                    else { return }
                    self.close(automatic: true)
                }
            })
    }

    // MARK: - Clicks outside

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps, including their menu bar items. On macOS 26 and later this
        // can include a click on this app's own status button.
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.clicked(inWindow: nil) }
            })
        {
            monitors.append(global)
        }
        // Clicks in this app's other windows.
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                let number = event.windowNumber
                MainActor.assumeIsolated { self?.clicked(inWindow: number) }
                return event
            })
        {
            monitors.append(local)
        }
    }

    /// - Parameter number: the window number of a click in this app, or nil for a click in
    ///   another app.
    private func clicked(inWindow number: Int?) {
        let click = PopoverDismissal.Click(
            location: NSEvent.mouseLocation, window: number.map(window(numbered:)))
        let button = anchor()?.window == nil ? nil : placement().anchor
        guard isShown,
            PopoverDismissal.closes(for: click, statusButton: button, panel: panel.frame)
        else { return }
        close(automatic: true)
    }

    private func window(numbered number: Int) -> PopoverDismissal.Window {
        if number == panel.windowNumber { return .panel }
        if let button = anchor()?.window, number == button.windowNumber { return .statusButton }
        guard let window = NSApp.window(withWindowNumber: number) else { return .other }
        return window.styleMask.contains(.titled) ? .titled : .other
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}

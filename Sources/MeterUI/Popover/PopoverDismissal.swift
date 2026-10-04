import CoreGraphics
import Foundation

/// When the popover closes by itself, and what a click on the status button does. Pure, so
/// the rules have tests.
///
/// One click changes the popover once. The status button opens and closes it; other clicks
/// outside the panel close it. On macOS 26 and later another process draws the menu bar, so a
/// click on the status button can reach the global mouse monitor before the button's action.
/// The monitors therefore ignore clicks on the button, and a toggle just after an automatic
/// close does nothing: it comes from the click that closed the panel.
enum PopoverDismissal {
    /// How far outside the status button a click still counts as a click on it.
    static let buttonSlop: CGFloat = 2
    /// A toggle this soon after an automatic close belongs to the same click.
    static let toggleDebounce: TimeInterval = 0.35

    /// The window of this app that received a click.
    enum Window: Equatable {
        case panel
        case statusButton
        /// A titled window: Settings, Sparkle's update window, the About panel.
        case titled
        /// A window that does not take the user away, such as a menu or a tooltip.
        case other
    }

    /// A mouse-down while the popover is open.
    struct Click: Equatable {
        /// Screen coordinates.
        var location: CGPoint
        /// Nil when the click went to another app.
        var window: Window?
    }

    /// Whether a click closes the popover. A click on the status button never does: the
    /// button's own action toggles the popover.
    static func closes(for click: Click, statusButton: CGRect?, panel: CGRect) -> Bool {
        if let statusButton, !statusButton.isEmpty,
            statusButton.insetBy(dx: -buttonSlop, dy: -buttonSlop).contains(click.location)
        {
            return false
        }
        switch click.window {
        case nil:
            return !panel.contains(click.location)
        case .titled:
            return true
        case .panel, .statusButton, .other:
            return false
        }
    }

    /// What a click on the status button does.
    enum Toggle: Equatable {
        case open
        case close
        /// The click already closed the popover through a monitor or a focus change.
        case ignore
    }

    /// - Parameters:
    ///   - now: system uptime, in seconds.
    ///   - lastAutomaticClose: the uptime of the last close that the user did not ask for
    ///     with the button or Escape.
    static func toggle(isShown: Bool, now: TimeInterval, lastAutomaticClose: TimeInterval?)
        -> Toggle
    {
        if isShown { return .close }
        if let lastAutomaticClose, now >= lastAutomaticClose,
            now - lastAutomaticClose < toggleDebounce
        {
            return .ignore
        }
        return .open
    }

    /// A change that may take the user away from the popover.
    enum Change: Equatable {
        /// Command-Tab, the Dock, or a click activated another app.
        case otherAppActivated
        /// Control-arrow, Mission Control, or a full-screen app changed the Space.
        case spaceChanged
        /// This app stopped being active, for example while Settings is open.
        case appResignedActive
        /// Command-H hid the app, which orders the panel out.
        case appHidden
        /// Another window took the keyboard, such as Spotlight.
        case panelResignedKey(toChildWindow: Bool)
    }

    /// Whether a change closes the popover. Only a child window of the panel keeps it open.
    static func closes(for change: Change) -> Bool {
        switch change {
        case .otherAppActivated, .spaceChanged, .appResignedActive, .appHidden: true
        case .panelResignedKey(let toChildWindow): !toChildWindow
        }
    }
}

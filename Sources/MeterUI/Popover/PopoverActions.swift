import CoreGraphics

/// What the popover views can ask the app to do.
@MainActor struct PopoverActions {
    /// Opens Settings on a tab, or on the tab that the user left. It also ends the welcome.
    var openSettings: (SettingsTab?) -> Void = { _ in }
    /// Closes the popover, then starts a user-initiated update check in Sparkle's window.
    var checkForUpdates: () -> Void = {}
    var quit: () -> Void = {}
    /// The header's height changed.
    var headerHeightChanged: (CGFloat) -> Void = { _ in }
    /// The natural height of the scrolling content changed.
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
}

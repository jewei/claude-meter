import CoreGraphics

/// What the popover views can ask the app to do.
@MainActor struct PopoverActions {
    var openSettings: () -> Void = {}
    /// Closes the popover, then starts a user-initiated update check in Sparkle's window.
    var checkForUpdates: () -> Void = {}
    var quit: () -> Void = {}
    /// The header's height changed.
    var headerHeightChanged: (CGFloat) -> Void = { _ in }
    /// The natural height of the scrolling content changed.
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
}

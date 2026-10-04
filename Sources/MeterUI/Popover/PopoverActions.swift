import CoreGraphics

/// What the popover views can ask the app to do.
@MainActor struct PopoverActions {
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    /// The header's height changed.
    var headerHeightChanged: (CGFloat) -> Void = { _ in }
    /// The natural height of the scrolling content changed.
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
}

import CoreGraphics

/// Where the Settings window goes and when the app keeps its Dock icon. Pure, so the rules
/// have tests.
enum SettingsWindowPlacement {
    /// `frame` moved and shortened so that it fits inside the visible frame. The top edge
    /// stays where it is when it can, so a saved position comes back. Pages scroll, so a
    /// shorter window loses nothing.
    static func fitted(_ frame: CGRect, in visible: CGRect) -> CGRect {
        guard !visible.isEmpty, frame.width.isFinite, frame.height.isFinite else { return frame }
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let top = min(max(frame.maxY, visible.minY + height), visible.maxY)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// One window of the app, as the activation policy sees it.
    struct Window: Equatable {
        var isTitled: Bool
        /// On screen or in the Dock.
        var isOpen: Bool
        var isClosing = false
    }

    /// Whether the app keeps the regular activation policy (Dock icon, menu bar,
    /// Command-Tab). It does while any titled window other than the closing one stays open,
    /// such as Sparkle's update window or the About panel.
    static func keepsDockIcon(_ windows: [Window]) -> Bool {
        windows.contains { $0.isTitled && $0.isOpen && !$0.isClosing }
    }
}

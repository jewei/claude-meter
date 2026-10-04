import CoreGraphics

/// Where the Settings window goes. Pure, so the rule has tests.
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
}

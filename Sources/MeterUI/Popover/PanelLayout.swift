import CoreGraphics

/// The size and place of the popover panel. Pure, so the rules have tests.
///
/// The panel is 360 pt wide. Its top edge sits just below the menu bar, centered under the
/// status button and kept inside the screen's visible frame. The body under the header is as
/// tall as its content, at least 120 pt, and at most `max(560, visible height − 72)`; taller
/// content scrolls.
enum PanelLayout {
    static let width: CGFloat = 360
    static let minimumBodyHeight: CGFloat = 120
    /// The smallest body cap, used on short screens.
    static let minimumBodyCap: CGFloat = 560
    /// Room kept free on the screen for the menu bar, the header, and margins.
    static let screenAllowance: CGFloat = 72
    /// The gap between the menu bar and the panel's top edge.
    static let topGap: CGFloat = 4
    /// The smallest distance between the panel and a side of the screen.
    static let sideMargin: CGFloat = 8

    /// The tallest the body can be on a screen.
    static func bodyCap(visibleHeight: CGFloat) -> CGFloat {
        max(minimumBodyCap, visibleHeight - screenAllowance)
    }

    /// The body height for content of a given natural height.
    static func bodyHeight(content: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        let content = content.isFinite ? content : minimumBodyHeight
        return max(minimumBodyHeight, min(content, bodyCap(visibleHeight: visibleHeight)))
    }

    /// Whether the content is taller than the body, so the body must scroll.
    static func scrolls(content: CGFloat, visibleHeight: CGFloat) -> Bool {
        content > bodyCap(visibleHeight: visibleHeight)
    }

    /// The panel frame in screen coordinates.
    ///
    /// - Parameters:
    ///   - header: the header height.
    ///   - content: the natural height of the scrolling content.
    ///   - anchor: the status button's frame in screen coordinates.
    ///   - visibleFrame: the visible frame of the button's screen (without the menu bar).
    static func frame(
        header: CGFloat, content: CGFloat, anchor: CGRect, visibleFrame: CGRect
    ) -> CGRect {
        let header = header.isFinite ? max(0, header) : 0
        let available = max(0, visibleFrame.height - topGap)
        let height = min(
            header + bodyHeight(content: content, visibleHeight: visibleFrame.height), available
        ).rounded(.up)
        // The top edge is the fixed point: a height change moves only the bottom edge. It
        // sits below the status button even when the menu bar hides itself.
        let menuBarBottom = anchor.isEmpty || !anchor.minY.isFinite ? .infinity : anchor.minY
        let top = (min(visibleFrame.maxY, menuBarBottom) - topGap).rounded(.down)
        let lowest = visibleFrame.minX + sideMargin
        let highest = max(lowest, visibleFrame.maxX - sideMargin - width)
        let centered = anchor.midX.isFinite ? anchor.midX - width / 2 : lowest
        let x = min(max(centered, lowest), highest).rounded()
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}

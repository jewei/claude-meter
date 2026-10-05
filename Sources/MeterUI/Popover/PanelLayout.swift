import CoreGraphics

/// The size and place of the popover panel, and whether its body scrolls. Pure, so the rules
/// have tests.
///
/// The panel is 360 pt wide. Its top edge sits 4 pt below the menu bar, or below the status
/// button when the menu bar hides itself, centered under the button and at least 8 pt from
/// the sides of the visible frame. The body under the header is as tall as its content, at
/// least 120 pt, and at most `max(560, visible height − 72)`. It never reaches below the
/// visible frame: on a short screen or under a hidden menu bar the body gets only the room
/// that is left. Content taller than the body scrolls, so every card can be reached.
struct PanelLayout: Equatable {
    static let width: CGFloat = 360
    static let minimumBodyHeight: CGFloat = 120
    /// The smallest body cap, used on short screens when the room allows it.
    static let minimumBodyCap: CGFloat = 560
    /// Room kept free on the screen for the menu bar, the header, and margins.
    static let screenAllowance: CGFloat = 72
    /// The gap between the menu bar and the panel's top edge.
    static let topGap: CGFloat = 4
    /// The smallest distance between the panel and a side of the screen.
    static let sideMargin: CGFloat = 8

    /// The panel frame in screen coordinates.
    let frame: CGRect
    /// The height below the header.
    let bodyHeight: CGFloat
    /// The content is taller than the body, so the body scrolls.
    let scrolls: Bool

    /// - Parameters:
    ///   - header: the header height.
    ///   - content: the natural height of the scrolling content.
    ///   - anchor: the status button's frame in screen coordinates.
    ///   - visibleFrame: the visible frame of the button's screen (without the menu bar).
    init(header: CGFloat, content: CGFloat, anchor: CGRect, visibleFrame: CGRect) {
        let header = header.isFinite ? max(0, header) : 0
        let content = content.isFinite ? max(0, content) : Self.minimumBodyHeight
        // The top edge is the fixed point: a height change moves only the bottom edge. It
        // sits below the status button even when the menu bar hides itself.
        let buttonBottom = anchor.isEmpty || !anchor.minY.isFinite ? .infinity : anchor.minY
        let top = (min(visibleFrame.maxY, buttonBottom) - Self.topGap).rounded(.down)
        let room = max(0, top - visibleFrame.minY)
        let cap = max(0, min(Self.bodyCap(visibleHeight: visibleFrame.height), room - header))
        let body = min(max(Self.minimumBodyHeight, content), cap)
        let height = min(room, (header + body).rounded(.up))

        let lowest = visibleFrame.minX + Self.sideMargin
        let highest = max(lowest, visibleFrame.maxX - Self.sideMargin - Self.width)
        let centered = anchor.midX.isFinite ? anchor.midX - Self.width / 2 : lowest
        let x = min(max(centered, lowest), highest).rounded()

        frame = CGRect(x: x, y: top - height, width: Self.width, height: height)
        bodyHeight = max(0, height - header)
        scrolls = content > bodyHeight
    }

    /// The tallest the body can be on a screen with room to spare.
    static func bodyCap(visibleHeight: CGFloat) -> CGFloat {
        max(minimumBodyCap, visibleHeight - screenAllowance)
    }
}

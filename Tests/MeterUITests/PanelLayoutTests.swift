import CoreGraphics
import Testing

@testable import MeterUI

@Suite struct PanelLayoutTests {
    /// A 1440×900 screen with a 25 pt menu bar.
    private let visible = CGRect(x: 0, y: 0, width: 1_440, height: 875)
    /// A status button in the menu bar, near the right edge.
    private let button = CGRect(x: 1_200, y: 875, width: 60, height: 25)

    private func layout(
        content: CGFloat, header: CGFloat = 56, anchor: CGRect? = nil, screen: CGRect? = nil
    ) -> PanelLayout {
        PanelLayout(
            header: header, content: content, anchor: anchor ?? button,
            visibleFrame: screen ?? visible)
    }

    @Test func bodyCapFollowsTheScreen() {
        #expect(PanelLayout.bodyCap(visibleHeight: 700) == 628)
        #expect(PanelLayout.bodyCap(visibleHeight: 900) == 828)
        // Short screens keep a 560 pt cap when the room allows it.
        #expect(PanelLayout.bodyCap(visibleHeight: 500) == 560)
    }

    @Test func bodyIsAsTallAsItsContentWithinLimits() {
        #expect(layout(content: 300).bodyHeight == 300)
        #expect(layout(content: 40).bodyHeight == 120)
        #expect(layout(content: 2_000).bodyHeight == 803)
        #expect(layout(content: .nan).bodyHeight == 120)
        #expect(!layout(content: 803).scrolls)
        #expect(layout(content: 804).scrolls)
        #expect(!layout(content: 40).scrolls)
    }

    @Test func panelHangsBelowTheMenuBarCenteredOnTheButton() {
        let frame = layout(content: 300).frame
        #expect(frame.width == 360)
        #expect(frame.height == 356)
        #expect(frame.maxY == 875 - PanelLayout.topGap)
        #expect(frame.midX == button.midX)
    }

    @Test func aHeightChangeMovesOnlyTheBottomEdge() {
        let small = layout(content: 300).frame
        let large = layout(content: 500).frame
        #expect(small.maxY == large.maxY)
        #expect(small.minX == large.minX)
        #expect(large.height - small.height == 200)
    }

    @Test func panelStaysInsideTheVisibleFrame() {
        let right = CGRect(x: 1_420, y: 875, width: 20, height: 25)
        #expect(layout(content: 300, anchor: right).frame.maxX == visible.maxX - 8)
        let left = CGRect(x: 0, y: 875, width: 20, height: 25)
        #expect(layout(content: 300, anchor: left).frame.minX == PanelLayout.sideMargin)
    }

    /// A short screen gets less than the 560 pt cap, and the body scrolls so that every
    /// card can be reached (review UI-12).
    @Test func shortScreenScrollsInsteadOfClipping() {
        let short = CGRect(x: 0, y: 0, width: 1_024, height: 555)
        let anchor = CGRect(x: 900, y: 555, width: 40, height: 22)
        let panel = layout(content: 540, anchor: anchor, screen: short)
        #expect(panel.frame.maxY == 551)
        #expect(panel.frame.minY == short.minY)
        #expect(panel.bodyHeight == 495)
        #expect(panel.scrolls)
    }

    @Test func tinyScreenNeverLeavesTheVisibleFrame() {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 100)
        let panel = layout(content: 2_000, anchor: .zero, screen: tiny)
        #expect(panel.frame.minY >= tiny.minY)
        #expect(panel.frame.maxY <= tiny.maxY)
        #expect(panel.bodyHeight == 40)
        #expect(panel.scrolls)
    }

    @Test func panelHangsBelowAHiddenMenuBar() {
        // With an auto-hiding menu bar the visible frame reaches the top of the screen.
        let full = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = layout(content: 300, screen: full).frame
        #expect(frame.maxY == button.minY - PanelLayout.topGap)
    }

    /// Tall content under a hidden menu bar stays inside the visible frame and scrolls
    /// (review UI-13).
    @Test func tallContentUnderAHiddenMenuBarStaysOnScreen() {
        let full = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let panel = layout(content: 2_000, screen: full)
        #expect(panel.frame.minY >= full.minY)
        #expect(panel.frame.maxY == 871)
        #expect(panel.bodyHeight == 815)
        #expect(panel.scrolls)
    }

    @Test func secondScreenUsesItsOwnFrame() {
        let second = CGRect(x: 1_440, y: -200, width: 1_920, height: 1_055)
        let anchor = CGRect(x: 3_000, y: 855, width: 40, height: 24)
        let panel = layout(content: 300, anchor: anchor, screen: second)
        #expect(panel.frame.maxY == 851)
        #expect(panel.frame.midX == anchor.midX)
    }
}

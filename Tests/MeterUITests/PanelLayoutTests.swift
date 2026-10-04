import CoreGraphics
import Testing

@testable import MeterUI

@Suite struct PanelLayoutTests {
    /// A 1440×900 screen with a 25 pt menu bar.
    private let visible = CGRect(x: 0, y: 0, width: 1_440, height: 875)
    /// A status button in the menu bar, near the right edge.
    private let button = CGRect(x: 1_200, y: 875, width: 60, height: 25)

    @Test func bodyCapFollowsTheScreen() {
        #expect(PanelLayout.bodyCap(visibleHeight: 700) == 628)
        #expect(PanelLayout.bodyCap(visibleHeight: 900) == 828)
        // Short screens keep a 560 pt cap.
        #expect(PanelLayout.bodyCap(visibleHeight: 500) == 560)
    }

    @Test func bodyIsAsTallAsItsContentWithinLimits() {
        #expect(PanelLayout.bodyHeight(content: 300, visibleHeight: 900) == 300)
        #expect(PanelLayout.bodyHeight(content: 40, visibleHeight: 900) == 120)
        #expect(PanelLayout.bodyHeight(content: 2_000, visibleHeight: 900) == 828)
        #expect(PanelLayout.bodyHeight(content: .nan, visibleHeight: 900) == 120)
        #expect(!PanelLayout.scrolls(content: 828, visibleHeight: 900))
        #expect(PanelLayout.scrolls(content: 829, visibleHeight: 900))
    }

    @Test func panelHangsBelowTheMenuBarCenteredOnTheButton() {
        let frame = PanelLayout.frame(
            header: 56, content: 300, anchor: button, visibleFrame: visible)
        #expect(frame.width == 360)
        #expect(frame.height == 356)
        #expect(frame.maxY == 875 - PanelLayout.topGap)
        #expect(frame.midX == button.midX)
    }

    @Test func aHeightChangeMovesOnlyTheBottomEdge() {
        let small = PanelLayout.frame(
            header: 56, content: 300, anchor: button, visibleFrame: visible)
        let large = PanelLayout.frame(
            header: 56, content: 500, anchor: button, visibleFrame: visible)
        #expect(small.maxY == large.maxY)
        #expect(small.minX == large.minX)
        #expect(large.height - small.height == 200)
    }

    @Test func panelStaysInsideTheVisibleFrame() {
        let right = CGRect(x: 1_420, y: 875, width: 20, height: 25)
        let frame = PanelLayout.frame(
            header: 56, content: 300, anchor: right, visibleFrame: visible)
        #expect(frame.maxX == visible.maxX - PanelLayout.sideMargin)
        let left = CGRect(x: 0, y: 875, width: 20, height: 25)
        #expect(
            PanelLayout.frame(header: 56, content: 300, anchor: left, visibleFrame: visible).minX
                == PanelLayout.sideMargin)
        // A tall body on a short screen is clamped to the screen.
        let short = CGRect(x: 0, y: 0, width: 1_440, height: 400)
        let tall = PanelLayout.frame(header: 56, content: 2_000, anchor: .zero, visibleFrame: short)
        #expect(tall.minY >= short.minY)
        #expect(tall.maxY <= short.maxY)
    }

    @Test func panelHangsBelowAHiddenMenuBar() {
        // With an auto-hiding menu bar the visible frame reaches the top of the screen.
        let full = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = PanelLayout.frame(header: 56, content: 300, anchor: button, visibleFrame: full)
        #expect(frame.maxY == button.minY - PanelLayout.topGap)
    }
}

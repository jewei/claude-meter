import CoreGraphics
import Testing

@testable import MeterUI

@Suite struct PopoverDismissalTests {
    private let button = CGRect(x: 1_200, y: 875, width: 30, height: 25)
    private let panel = CGRect(x: 1_035, y: 515, width: 360, height: 356)

    private func closes(_ x: CGFloat, _ y: CGFloat, in window: PopoverDismissal.Window?) -> Bool {
        PopoverDismissal.closes(
            for: .init(location: CGPoint(x: x, y: y), window: window), statusButton: button,
            panel: panel)
    }

    /// The menu bar of macOS 26 lives in another process, so a click on the status button
    /// reaches the global monitor. The button toggles; the monitor must not close first
    /// (review UI-01).
    @Test func aClickOnTheStatusButtonNeverClosesFromAMonitor() {
        #expect(!closes(1_210, 885, in: nil))
        #expect(!closes(1_210, 885, in: .statusButton))
        // The 2 pt slop around the button still counts.
        #expect(!closes(1_199, 874, in: nil))
        #expect(closes(1_196, 885, in: nil))
    }

    @Test func clicksInOtherAppsClose() {
        #expect(closes(100, 100, in: nil))
        #expect(closes(1_100, 890, in: nil))
    }

    @Test func clicksInThisAppCloseOnlyInTitledWindows() {
        #expect(closes(300, 300, in: .titled))
        #expect(!closes(1_100, 600, in: .panel))
        // Context menus and tooltips of the panel are other windows.
        #expect(!closes(1_100, 600, in: .other))
        #expect(!closes(100, 100, in: .other))
    }

    @Test func aMissingButtonFrameStillClosesForOutsideClicks() {
        let click = PopoverDismissal.Click(location: CGPoint(x: 10, y: 10), window: nil)
        #expect(PopoverDismissal.closes(for: click, statusButton: nil, panel: panel))
        #expect(PopoverDismissal.closes(for: click, statusButton: .zero, panel: panel))
    }

    @Test func toggleClosesAnOpenPopover() {
        #expect(PopoverDismissal.toggle(isShown: true, now: 10, lastAutomaticClose: 9.9) == .close)
        #expect(PopoverDismissal.toggle(isShown: true, now: 10, lastAutomaticClose: nil) == .close)
    }

    /// One click closes and does not reopen: a toggle that arrives just after an automatic
    /// close belongs to the same click.
    @Test func toggleIsIdempotentForOneClick() {
        #expect(
            PopoverDismissal.toggle(isShown: false, now: 10, lastAutomaticClose: 9.9) == .ignore)
        #expect(PopoverDismissal.toggle(isShown: false, now: 10, lastAutomaticClose: 10) == .ignore)
        #expect(PopoverDismissal.toggle(isShown: false, now: 10, lastAutomaticClose: 9.6) == .open)
        #expect(PopoverDismissal.toggle(isShown: false, now: 10, lastAutomaticClose: nil) == .open)
        // A close in the future is a clock change, not this click.
        #expect(PopoverDismissal.toggle(isShown: false, now: 10, lastAutomaticClose: 11) == .open)
    }

    /// Command-Tab, Space changes, Command-H, and Spotlight leave the popover (review UI-02,
    /// UI-36).
    @Test func leavingThePopoverClosesIt() {
        #expect(PopoverDismissal.closes(for: .otherAppActivated))
        #expect(PopoverDismissal.closes(for: .spaceChanged))
        #expect(PopoverDismissal.closes(for: .appResignedActive))
        #expect(PopoverDismissal.closes(for: .appHidden))
        #expect(PopoverDismissal.closes(for: .panelResignedKey(toChildWindow: false)))
        #expect(!PopoverDismissal.closes(for: .panelResignedKey(toChildWindow: true)))
    }
}

import AppKit
import Testing

@testable import MeterUI

/// The panel is built without being shown, so no test puts a window on screen.
@MainActor
@Suite struct PopoverPanelTests {
    /// The popover never activates the app, so its tooltips must be allowed while the app is
    /// inactive (review R3-U-04).
    @Test func showsTooltipsWhileTheAppIsInactive() {
        let panel = PopoverPanel()
        #expect(panel.allowsToolTipsWhenApplicationIsInactive)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }
}

import Testing

@testable import MeterUI

@Suite struct DockIconPolicyTests {
    private typealias Window = DockIconPolicy.Window

    /// Closing Settings keeps the Dock icon while Sparkle's window is open (review UI-24).
    @Test func theDockIconStaysWhileAnotherTitledWindowIsOpen() {
        let settings = Window(isTitled: true, isOpen: true, isClosing: true)
        let popover = Window(isTitled: false, isOpen: true)
        let sparkle = Window(isTitled: true, isOpen: true)
        let minimized = Window(isTitled: true, isOpen: true)
        let closed = Window(isTitled: true, isOpen: false)
        #expect(!DockIconPolicy.keepsDockIcon([settings, popover, closed]))
        #expect(DockIconPolicy.keepsDockIcon([settings, popover, sparkle]))
        #expect(DockIconPolicy.keepsDockIcon([minimized]))
        #expect(!DockIconPolicy.keepsDockIcon([]))
    }
}

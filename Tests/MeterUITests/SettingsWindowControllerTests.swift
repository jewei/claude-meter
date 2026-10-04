import AppKit
import MeterApp
import SwiftUI
import Testing

@testable import MeterUI

/// The window is built without being shown, so no test puts a window on screen.
@MainActor
@Suite struct SettingsWindowControllerTests {
    /// A new window has a plain content view; Settings must replace it on the first open
    /// (review R3-U-01).
    @Test func theFirstOpenShowsTheSettingsContent() {
        let controller = SettingsWindowController(model: .preview())
        let window = controller.preparedWindow()
        #expect(window.contentView is NSHostingView<SettingsView>)
        window.close()
    }

    @Test func aClosedWindowGetsItsContentBack() {
        let controller = SettingsWindowController(model: .preview())
        let window = controller.preparedWindow()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(window.contentView == nil)
        #expect(controller.preparedWindow() === window)
        #expect(window.contentView is NSHostingView<SettingsView>)
        window.close()
    }
}

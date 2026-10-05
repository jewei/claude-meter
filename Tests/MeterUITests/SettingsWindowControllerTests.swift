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

    /// A launch-at-login error stays when the window closes while macOS still disagrees, so
    /// the next open shows it again (review R4-U-02).
    @Test func theLaunchAtLoginErrorOutlivesTheWindow() throws {
        let macOS = FakeLoginItem()
        macOS.failure = "Claude Meter could not turn on launch at login."
        let state = macOS.state()
        let controller = SettingsWindowController(model: .preview(), launchAtLogin: state)
        let window = controller.preparedWindow()
        state.choose(true)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        _ = controller.preparedWindow()
        let content = try #require(window.contentView as? NSHostingView<SettingsView>)
        #expect(content.rootView.launchAtLogin === state)
        #expect(state.error.text == macOS.failure)
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

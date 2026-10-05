import Foundation
import Testing

@testable import MeterUI

/// Only the newest inline question or token form answers Escape (review R3-U-11).
@MainActor @Suite struct CancelShortcutsTests {
    @Test func theNewestClaimOwnsEscape() {
        let shortcuts = CancelShortcuts()
        let form = UUID()
        let question = UUID()
        shortcuts.appear(form)
        #expect(shortcuts.owns(form))
        shortcuts.appear(question)
        #expect(shortcuts.owns(question))
        #expect(!shortcuts.owns(form))
        // The question closes, so the form gets Escape back.
        shortcuts.disappear(question)
        #expect(shortcuts.owns(form))
        shortcuts.disappear(form)
        #expect(!shortcuts.owns(form))
    }

    /// A view that appears again, such as after a redraw, keeps its place in the order.
    @Test func appearingTwiceDoesNotMakeAClaimNewer() {
        let shortcuts = CancelShortcuts()
        let older = UUID()
        let newer = UUID()
        shortcuts.appear(older)
        shortcuts.appear(newer)
        shortcuts.appear(older)
        #expect(shortcuts.owns(newer))
    }
}

import CoreGraphics
import Testing

@testable import MeterUI

@Suite struct SettingsWindowPlacementTests {
    private typealias Window = SettingsWindowPlacement.Window

    /// A 13-inch MacBook Air at "Larger Text" with the Dock shown (review UI-08).
    private let small = CGRect(x: 0, y: 80, width: 1_280, height: 715)

    @Test func aTallWindowShrinksToTheVisibleFrame() {
        let window = CGRect(x: 350, y: 60, width: 580, height: 732)
        let fitted = SettingsWindowPlacement.fitted(window, in: small)
        #expect(fitted.height == 715)
        #expect(fitted.minY == small.minY)
        #expect(fitted.maxY == small.maxY)
        #expect(fitted.minX == 350)
    }

    @Test func aWindowThatFitsKeepsItsPlace() {
        let window = CGRect(x: 200, y: 150, width: 580, height: 500)
        #expect(SettingsWindowPlacement.fitted(window, in: small) == window)
    }

    @Test func aWindowOffScreenMovesBackKeepingItsSize() {
        let below = CGRect(x: -100, y: -300, width: 580, height: 500)
        let fitted = SettingsWindowPlacement.fitted(below, in: small)
        #expect(fitted.size == below.size)
        #expect(fitted.minX == 0)
        #expect(fitted.minY == small.minY)
        let right = CGRect(x: 1_200, y: 300, width: 580, height: 500)
        #expect(SettingsWindowPlacement.fitted(right, in: small).maxX == small.maxX)
        let above = CGRect(x: 200, y: 700, width: 580, height: 500)
        #expect(SettingsWindowPlacement.fitted(above, in: small).maxY == small.maxY)
    }

    @Test func anEmptyScreenChangesNothing() {
        let window = CGRect(x: 1, y: 2, width: 580, height: 700)
        #expect(SettingsWindowPlacement.fitted(window, in: .zero) == window)
    }

    /// Closing Settings keeps the Dock icon while Sparkle's window or the About panel is
    /// open (review UI-24).
    @Test func theDockIconStaysWhileAnotherTitledWindowIsOpen() {
        let settings = Window(isTitled: true, isOpen: true, isClosing: true)
        let popover = Window(isTitled: false, isOpen: true)
        let sparkle = Window(isTitled: true, isOpen: true)
        let minimized = Window(isTitled: true, isOpen: true)
        let closed = Window(isTitled: true, isOpen: false)
        #expect(!SettingsWindowPlacement.keepsDockIcon([settings, popover, closed]))
        #expect(SettingsWindowPlacement.keepsDockIcon([settings, popover, sparkle]))
        #expect(SettingsWindowPlacement.keepsDockIcon([minimized]))
        #expect(!SettingsWindowPlacement.keepsDockIcon([]))
    }
}

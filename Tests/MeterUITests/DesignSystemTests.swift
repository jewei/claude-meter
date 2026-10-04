import AppKit
import SwiftUI
import Testing

@testable import MeterUI

@MainActor @Suite struct DesignSystemTests {
    @Test func bundledFacesRegister() {
        MeterFont.registerBundledFonts()
        #expect(
            MeterFont.availableFaces == [
                "Fredoka-Regular", "Fredoka-SemiBold", "Fredoka-Bold", "Nunito-SemiBold",
                "Nunito-Bold", "Nunito-ExtraBold",
            ])
    }

    @Test func paletteAdaptsToTheAppearance() throws {
        let color = Palette.popoverBackground
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        var lightColor: NSColor?
        var darkColor: NSColor?
        light.performAsCurrentDrawingAppearance { lightColor = color.usingColorSpace(.sRGB) }
        dark.performAsCurrentDrawingAppearance { darkColor = color.usingColorSpace(.sRGB) }
        #expect(lightColor == NSColor(hex: 0xFBF9F2).usingColorSpace(.sRGB))
        #expect(darkColor == NSColor(hex: 0x201E18).usingColorSpace(.sRGB))
    }

    @Test func energyBarHidesItsHighlightOnTinyFills() {
        #expect(EnergyBar.fillWidth(fraction: 0.5, in: 200) == 100)
        #expect(EnergyBar.fillWidth(fraction: 1.4, in: 200) == 200)
        #expect(EnergyBar.fillWidth(fraction: -1, in: 200) == 0)
        #expect(EnergyBar.fillWidth(fraction: .nan, in: 200) == 0)
        #expect(!EnergyBar.showsHighlight(fillWidth: 6))
        #expect(EnergyBar.showsHighlight(fillWidth: 6.5))
    }

    @Test func thresholdSliderSnapsAndSteps() {
        let range = 50.0...90.0
        #expect(ThresholdSlider.snapped(72.4, in: range, step: 5) == 70)
        #expect(ThresholdSlider.snapped(73, in: range, step: 5) == 75)
        #expect(ThresholdSlider.snapped(120, in: range, step: 5) == 90)
        #expect(ThresholdSlider.stepped(90, up: true, in: range, step: 5) == 90)
        #expect(ThresholdSlider.stepped(80, up: false, in: range, step: 5) == 75)
        #expect(ThresholdSlider.stepped(.nan, up: true, in: range, step: 5) == 55)
        #expect(ThresholdSlider.fraction(for: 70, in: range) == 0.5)
        #expect(ThresholdSlider.fraction(for: 70, in: 70...70) == 0)
    }

    @Test func avatarColorIsStablePerAccount() {
        let index = AccountAvatar.paletteIndex(for: "claude-work")
        #expect(index == AccountAvatar.paletteIndex(for: "claude-work"))
        #expect(AccountAvatar.palette.indices.contains(index))
    }

    @Test func secondClockTicksOnWholeSecondsOnlyWhileRunning() {
        let start = Date(timeIntervalSinceReferenceDate: 100.4)
        let running = Array(
            SecondClock(isPaused: false).entries(from: start, mode: .normal).prefix(3))
        #expect(running.map(\.timeIntervalSinceReferenceDate) == [100.4, 101, 102])
        let paused = Array(
            SecondClock(isPaused: true).entries(from: start, mode: .normal).prefix(3))
        #expect(paused == [start])
    }

    @Test func statusMessagesRenderInlineCode() {
        let message = StatusScreenView.message("Run `codex login` first.")
        #expect(String(message.characters) == "Run codex login first.")
        #expect(message.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }
}

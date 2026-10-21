import AppKit
import Foundation
import MeterApp
import MeterDomain
import SwiftUI
import Testing

@testable import MeterUI

@MainActor @Suite struct MenuBarImageTests {
    private func image(_ model: MenuBarModel) -> MenuBarImage? {
        MenuBarImage.make(MenuBarLabel(model: model), padding: 5, height: 22, scales: [1, 2])
    }

    /// A Claude reading with `session` percent used.
    private func model(session: Double) -> MenuBarModel {
        let now = Date()
        let account = AccountUsage(
            id: "claude", name: "default", plan: "Pro",
            windows: [
                QuotaWindow(
                    id: "session", title: "Session", kind: .session, usedPercent: session,
                    resetsAt: now.addingTimeInterval(3_600), isBinding: true)
            ],
            observedAt: now)
        let usage = ProviderUsage(provider: .claude, accounts: [account])
        return MenuBarModel(
            PresentationContext(
                settings: .preview, readings: [.claude: .current(usage, observedAt: now)],
                refreshing: [], now: now))
    }

    @Test func sizeFollowsTheLabelInWholePoints() throws {
        let wide = try #require(image(AppModel.preview().menuBarModel(at: Date())))
        #expect(wide.ink.size.width > 50)
        #expect(wide.ink.size.width == wide.ink.size.width.rounded())
        #expect(wide.ink.size.height == 22)
        let narrow = try #require(image(AppModel.preview(readings: []).menuBarModel(at: Date())))
        #expect(narrow.ink.size.width < wide.ink.size.width)
        #expect(narrow.ink.size.width > 10)
    }

    /// The system dims a template on an inactive display as much as the other items.
    @Test func inkIsATemplateAndThePillLinesUp() throws {
        let image = try #require(image(model(session: 100)))
        #expect(image.ink.isTemplate)
        let badge = try #require(image.badge)
        #expect(!badge.isTemplate)
        #expect(badge.size == image.ink.size)
        #expect(Set(image.ink.representations.map(\.pixelsWide)).count == 2)
    }

    /// Only the red "0" pill keeps its colors.
    @Test func noColoredLayerWithEnergyLeft() throws {
        #expect(try #require(image(model(session: 97))).badge == nil)
        #expect(
            try #require(image(AppModel.preview(readings: []).menuBarModel(at: Date()))).badge
                == nil)
    }

    /// The pill is drawn in the appearance of the menu bar that draws it.
    @Test func pillDrawsInTheAppearanceOfTheMenuBar() throws {
        let image = try #require(image(model(session: 100)))
        let badge = try #require(image.badge)
        func pixels(_ appearance: NSAppearance.Name) throws -> Data {
            let size = badge.size
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2,
                    pixelsHigh: Int(size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                    bitsPerPixel: 0))
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                badge.draw(in: NSRect(origin: .zero, size: size))
            }
            NSGraphicsContext.restoreGraphicsState()
            return try #require(bitmap.tiffRepresentation)
        }
        // Drawn twice in a row in different appearances: no cache keeps the first one.
        #expect(try pixels(.darkAqua) != pixels(.aqua))
    }
}

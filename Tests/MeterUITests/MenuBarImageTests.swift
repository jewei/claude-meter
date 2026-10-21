import AppKit
import Foundation
import MeterApp
import SwiftUI
import Testing

@testable import MeterUI

@MainActor @Suite struct MenuBarImageTests {
    private func image(_ model: MenuBarModel, scales: Set<CGFloat> = [1, 2]) -> NSImage? {
        MenuBarImage.make(MenuBarLabel(model: model), padding: 5, height: 22, scales: scales)
    }

    @Test func sizeFollowsTheLabelInWholePoints() throws {
        let wide = try #require(image(AppModel.preview().menuBarModel(at: Date())))
        #expect(wide.size.width > 50)
        #expect(wide.size.width == wide.size.width.rounded())
        #expect(wide.size.height == 22)
        let narrow = try #require(
            image(AppModel.preview(readings: []).menuBarModel(at: Date())))
        #expect(narrow.size.width < wide.size.width)
        #expect(narrow.size.width > 10)
    }

    /// The label is drawn in the appearance of the menu bar that draws it.
    @Test func drawsInTheAppearanceOfTheMenuBar() throws {
        let image = try #require(image(AppModel.preview().menuBarModel(at: Date())))
        func darkestInk(_ appearance: NSAppearance.Name, scale: Int) throws -> CGFloat {
            let size = image.size
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                    pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                    bitsPerPixel: 0))
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                image.draw(in: NSRect(origin: .zero, size: size))
            }
            NSGraphicsContext.restoreGraphicsState()
            // The darkest opaque pixel: the ink of the bolt and the number. The dot is bright
            // in both appearances.
            var darkest: CGFloat = 1
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5
                    else { continue }
                    darkest = min(darkest, color.brightnessComponent)
                }
            }
            return darkest
        }
        for scale in [1, 2] {
            #expect(try darkestInk(.darkAqua, scale: scale) > 0.5)
            #expect(try darkestInk(.aqua, scale: scale) < 0.2)
        }
    }
}

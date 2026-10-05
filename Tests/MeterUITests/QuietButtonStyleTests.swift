import AppKit
import SwiftUI
import Testing

@testable import MeterUI

/// The press surface of ``QuietButtonStyle`` shows on every button, also on one that stands
/// on a chunky surface or a fill of its own (review R3-U-02: the label's opaque fill hid it).
@MainActor @Suite struct QuietButtonStyleTests {
    /// The sRGB pixels of a rendered view at 1×, top row first.
    @MainActor private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ view: some View, dark: Bool) throws {
            let renderer = ImageRenderer(
                content: view.environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(
                    image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            try #require(drawn)
            self.bytes = bytes
        }

        /// The red, green, and blue values at `x`, `y`, counted from the top left.
        func color(x: Int, y: Int) -> [Int] {
            let start = (y * width + x) * 4
            return bytes[start..<start + 3].map(Int.init)
        }
    }

    /// The sum of the channel differences between the button at rest and pressed, at a point
    /// on its surface beside the title.
    private func pressChange(surface: QuietButtonStyle.Surface, dark: Bool) throws -> Int {
        func button(pressed: Bool) -> some View {
            QuietButtonBody(isPressed: pressed, radius: 12, surface: surface) {
                ChunkyButtonLabel(title: "Cancel")
            }
            .padding(8)
            .background(Palette.popover)
        }
        let rest = try Pixels(button(pressed: false), dark: dark)
        let pressed = try Pixels(button(pressed: true), dark: dark)
        #expect(rest.width == pressed.width && rest.height == pressed.height)
        // 8 pt of padding, then 6 pt into the label's 14 pt leading inset, at mid height:
        // inside the 2 pt border and away from the title.
        let x = 14
        let y = rest.height / 2
        return zip(rest.color(x: x, y: y), pressed.color(x: x, y: y)).map { abs($0 - $1) }
            .reduce(0, +)
    }

    @Test(arguments: [false, true])
    func aChunkyButtonChangesWhenPressed(dark: Bool) throws {
        // The press surface is ink at 10%: well over 10 levels across the three channels.
        #expect(try pressChange(surface: .chunky, dark: dark) >= 15)
    }

    @Test(arguments: [false, true])
    func aButtonWithItsOwnFillChangesWhenPressed(dark: Bool) throws {
        #expect(try pressChange(surface: .fill(Palette.popover), dark: dark) >= 15)
    }
}

import AppKit
import SwiftUI
import Testing

@testable import MeterUI

/// Every text color on the background that the UI puts it on reaches WCAG 4.5:1 in light and
/// dark appearance (`docs/design.md`, Accessibility). Tinted fills and the hover and press
/// surfaces of ``QuietButtonStyle`` are blended in.
@MainActor @Suite struct ContrastTests {
    /// A resolved sRGB color.
    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double

        /// `self` drawn at `alpha` over `background`.
        func over(_ background: RGB, alpha: Double) -> RGB {
            RGB(
                red: red * alpha + background.red * (1 - alpha),
                green: green * alpha + background.green * (1 - alpha),
                blue: blue * alpha + background.blue * (1 - alpha))
        }

        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(with other: RGB) -> Double {
            let high = max(luminance, other.luminance)
            let low = min(luminance, other.luminance)
            return (high + 0.05) / (low + 0.05)
        }
    }

    private func resolve(_ color: Color, dark: Bool) throws -> RGB {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let color = try #require(resolved)
        return RGB(
            red: Double(color.redComponent), green: Double(color.greenComponent),
            blue: Double(color.blueComponent))
    }

    /// One text color on one background, as the UI draws it.
    private struct Pair {
        let name: String
        let text: Color
        let background: Color
        /// A tint drawn over `background` first, at this opacity.
        var tint: (Color, Double)?
        /// Also check the hover and press ink surfaces.
        var isButton = false
    }

    private static let pairs: [Pair] = [
        Pair(name: "ink on popover", text: Palette.ink, background: Palette.popover),
        Pair(name: "ink on card", text: Palette.ink, background: Palette.card),
        Pair(
            name: "muted on popover", text: Palette.inkMuted, background: Palette.popover,
            isButton: true),
        Pair(name: "muted on card", text: Palette.inkMuted, background: Palette.card),
        Pair(name: "section label", text: Palette.sectionLabel, background: Palette.popover),
        Pair(name: "chip", text: Palette.inkMuted, background: Palette.track),
        Pair(
            name: "menu bar pill", text: Palette.inkMuted, background: Palette.popover,
            tint: (Palette.track, 0.65)),
        Pair(
            name: "path chip", text: Palette.inkMuted, background: Palette.popover,
            tint: (Palette.track, 0.8)),
        Pair(name: "green text", text: Palette.energyFullInk, background: Palette.card),
        Pair(name: "amber text", text: Palette.energyLowInk, background: Palette.card),
        Pair(name: "amber on popover", text: Palette.energyLowInk, background: Palette.popover),
        Pair(name: "red text", text: Palette.energyEmptyInk, background: Palette.card),
        Pair(name: "red on popover", text: Palette.energyEmptyInk, background: Palette.popover),
        Pair(
            name: "warning notice", text: Palette.energyLowInk, background: Palette.popover,
            tint: (Palette.energyLowInk, 0.08)),
        Pair(
            name: "info notice", text: Palette.inkMuted, background: Palette.popover,
            tint: (Palette.inkMuted, 0.08)),
        // Review UI-19: the green text was 4.42:1 and lower on hover.
        Pair(
            name: "update notice", text: Palette.ink, background: Palette.popover,
            tint: (Palette.energyFullInk, 0.08), isButton: true),
        Pair(
            name: "hero full title", text: Palette.heroFull.ink,
            background: Palette.heroFull.background),
        Pair(
            name: "hero full subtitle", text: Palette.heroFull.subink,
            background: Palette.heroFull.background),
        Pair(
            name: "hero low title", text: Palette.heroLow.ink,
            background: Palette.heroLow.background),
        Pair(
            name: "hero low subtitle", text: Palette.heroLow.subink,
            background: Palette.heroLow.background),
        Pair(
            name: "hero empty title", text: Palette.heroEmpty.ink,
            background: Palette.heroEmpty.background),
        Pair(
            name: "hero empty subtitle", text: Palette.heroEmpty.subink,
            background: Palette.heroEmpty.background),
        // Selected tabs and options are buttons on the hero-full fill.
        Pair(
            name: "selected option", text: Palette.heroFull.ink,
            background: Palette.heroFull.background, isButton: true),
        Pair(
            name: "plan max", text: Palette.planMax.foreground,
            background: Palette.planMax.background),
        Pair(
            name: "plan pro", text: Palette.planPro.foreground,
            background: Palette.planPro.background),
        Pair(
            name: "plan free", text: Palette.planFree.foreground,
            background: Palette.planFree.background),
        Pair(name: "raised button", text: .white, background: Palette.action),
        Pair(name: "destructive button", text: .white, background: Palette.destructive),
        Pair(
            name: "warning threshold", text: Palette.energyLowInk, background: Palette.card,
            tint: (Palette.energyLow, 0.16)),
        Pair(
            name: "critical threshold", text: Palette.energyEmptyInk, background: Palette.card,
            tint: (Palette.energyEmpty, 0.16)),
    ]

    @Test(arguments: [false, true])
    func everyTextPairReachesFourAndAHalf(dark: Bool) throws {
        for pair in Self.pairs {
            var background = try resolve(pair.background, dark: dark)
            if let (tint, alpha) = pair.tint {
                background = try resolve(tint, dark: dark).over(background, alpha: alpha)
            }
            let text = try resolve(pair.text, dark: dark)
            let ink = try resolve(Palette.ink, dark: dark)
            let surfaces =
                pair.isButton
                ? [
                    background, ink.over(background, alpha: QuietButtonStyle.hoverOpacity),
                    ink.over(background, alpha: QuietButtonStyle.pressOpacity),
                ]
                : [background]
            for surface in surfaces {
                let ratio = text.contrast(with: surface)
                let shown = ratio.formatted(.number.precision(.fractionLength(2)))
                #expect(ratio >= 4.5, "\(pair.name) is \(shown) in \(dark ? "dark" : "light")")
            }
        }
    }
}

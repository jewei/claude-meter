import AppKit
import SwiftUI

/// The color tokens of the design system (`docs/design.md`).
///
/// Every token is an `NSColor` with a dynamic provider, so one value serves light and dark
/// appearance in SwiftUI, in AppKit chrome, and in the menu bar.
enum Palette {
    // MARK: Surfaces

    static let popoverBackground = NSColor.adaptive("popover", light: 0xFBF9F2, dark: 0x201E18)
    static let popover = Color(nsColor: popoverBackground)
    static let popoverBorder = Color.adaptive("popoverBorder", light: 0xEFE9DA, dark: 0x3A372E)
    static let card = Color.adaptive("card", light: 0xFFFFFF, dark: 0x2A2820)
    static let cardBorder = Color.adaptive("cardBorder", light: 0xEFEAD9, dark: 0x3D3A30)
    /// The solid plate that peeks out below a card for depth.
    static let cardLip = Color.adaptive("cardLip", light: 0xE4DDC9, dark: 0x15140F)
    /// The unfilled part of rings and bars, and neutral chips.
    static let track = Color.adaptive("track", light: 0xECE9DD, dark: 0x3A372E)

    // MARK: Text

    static let ink = Color.adaptive("ink", light: 0x3A382F, dark: 0xECE8DC)
    static let inkMuted = Color.adaptive("inkMuted", light: 0x6A665B, dark: 0xADA798)
    static let sectionLabel = inkMuted

    // MARK: Energy

    static let energyFull = Color.adaptive("energyFull", light: 0x4FC51C, dark: 0x62D62C)
    static let energyLow = Color.adaptive("energyLow", light: 0xFF9D0A, dark: 0xFFAE33)
    static let energyEmpty = Color.adaptive("energyEmpty", light: 0xFF5A5A, dark: 0xFF6B6B)
    /// Darker energy colors for small text, which needs more contrast than fills.
    static let energyFullInk = Color.adaptive("energyFullInk", light: 0x2E7D12, dark: 0x8FE25A)
    static let energyLowInk = Color.adaptive("energyLowInk", light: 0x965000, dark: 0xFFC368)
    static let energyEmptyInk = Color.adaptive("energyEmptyInk", light: 0xB52C28, dark: 0xFF9B96)
    /// Unknown values. The fill is zero, so this color shows only in dots.
    static let energyUnknown = inkMuted.opacity(0.45)

    // MARK: Actions

    /// The raised primary button fill. Dark in both modes so white text stays readable.
    static let action = Color(nsColor: NSColor(hex: 0x287B12))
    static let actionShadow = Color(nsColor: NSColor(hex: 0x19550B))
    /// Tint for native controls, focus rings, and selected options.
    static let accent = energyFullInk

    // MARK: Hero

    static let heroFull = HeroColors(
        background: .adaptive("heroFullBG", light: 0xEAF8E0, dark: 0x22311A),
        border: .adaptive("heroFullBorder", light: 0xCFEEB8, dark: 0x3C5A2A),
        ink: .adaptive("heroFullInk", light: 0x2E7D12, dark: 0x8FE25A),
        subink: .adaptive("heroFullSub", light: 0x547236, dark: 0xA6C98A))
    static let heroLow = HeroColors(
        background: .adaptive("heroLowBG", light: 0xFFF1DD, dark: 0x332715),
        border: .adaptive("heroLowBorder", light: 0xFAD9A0, dark: 0x5A4424),
        ink: .adaptive("heroLowInk", light: 0x965000, dark: 0xFFC368),
        subink: .adaptive("heroLowSub", light: 0x8A6A3A, dark: 0xD8B488))
    static let heroEmpty = HeroColors(
        background: .adaptive("heroEmptyBG", light: 0xFFE4E1, dark: 0x3A1F1E),
        border: .adaptive("heroEmptyBorder", light: 0xF6C0BC, dark: 0x5E2F2D),
        ink: .adaptive("heroEmptyInk", light: 0xC0322E, dark: 0xFF9B96),
        subink: .adaptive("heroEmptySub", light: 0x8A4B47, dark: 0xE0A8A4))
    static let heroNeutral = HeroColors(
        background: card, border: cardBorder, ink: ink, subink: inkMuted)

    // MARK: Plan badges

    static let planMax = BadgeColors(
        foreground: .adaptive("planMaxFG", light: 0x8133BC, dark: 0xD9B3FF),
        background: .adaptive("planMaxBG", light: 0xF2E6FF, dark: 0x3A2A50))
    static let planPro = BadgeColors(
        foreground: .adaptive("planProFG", light: 0x287B12, dark: 0x7FD65A),
        background: .adaptive("planProBG", light: 0xE7F8DC, dark: 0x23381A))
    static let planFree = BadgeColors(
        foreground: .adaptive("planFreeFG", light: 0x6F6A5B, dark: 0xB8B3A2),
        background: .adaptive("planFreeBG", light: 0xEFECE0, dark: 0x33312A))

    // MARK: Tiles

    /// Bright fills for the icon tiles in Settings. White glyphs sit on them.
    enum Tile {
        static let sky = Color(nsColor: NSColor(hex: 0x25B6F0))
        static let violet = Color(nsColor: NSColor(hex: 0xC77DFF))
        static let orange = Color(nsColor: NSColor(hex: 0xFF9D0A))
        static let green = Color(nsColor: NSColor(hex: 0x4FC51C))
        static let teal = Color(nsColor: NSColor(hex: 0x2DD4BF))
        static let gold = Color(nsColor: NSColor(hex: 0xF4B400))
        static let cyan = Color(nsColor: NSColor(hex: 0x4CC9F0))
        static let slate = Color(nsColor: NSColor(hex: 0x8D99AE))
        static let lagoon = Color(nsColor: NSColor(hex: 0x49A3B0))
        static let graphite = Color(nsColor: NSColor(hex: 0x1C1C1E))
    }
}

/// The four colors of one hero state.
struct HeroColors: Equatable, Sendable {
    let background: Color
    let border: Color
    let ink: Color
    let subink: Color
}

/// Foreground and background of a plan badge.
struct BadgeColors: Equatable, Sendable {
    let foreground: Color
    let background: Color
}

extension NSColor {
    /// An sRGB color from a `0xRRGGBB` literal.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A color that resolves to `light` or `dark` for the drawing appearance.
    static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        let lightColor = NSColor(hex: light)
        let darkColor = NSColor(hex: dark)
        return NSColor(name: "ClaudeMeter.\(name)") { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}

extension Color {
    /// A SwiftUI color backed by ``NSColor/adaptive(_:light:dark:)``.
    static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: .adaptive(name, light: light, dark: dark))
    }
}

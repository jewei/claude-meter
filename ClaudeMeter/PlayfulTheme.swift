import ClaudeMeterCore
import SwiftUI

// MARK: - Playful palette (Duolingo-flavored, adaptive light/dark)
//
// Source of truth: DESIGN.md / "Claude Usage Popup.dc.html". The design ships
// light-only; the dark values are our faithful warm-dark counterpart. Reuses
// `Color(hex:)` / `Color(light:dark:)` from DesignTokens.swift.

extension Color {
    // Shell & surfaces
    static let pfPopover = Color(light: "FBF9F2", dark: "201E18")
    static let pfPopoverBorder = Color(light: "EFE9DA", dark: "3A372E")
    static let pfCard = Color(light: "FFFFFF", dark: "2A2820")
    static let pfCardBorder = Color(light: "EFEAD9", dark: "3D3A30")
    /// The chunky 3D "lip" peeking below a card — darker than the border.
    static let pfCardLip = Color(light: "E4DDC9", dark: "15140F")
    static let pfTrack = Color(light: "ECE9DD", dark: "3A372E")

    // Ink
    static let pfInk = Color(light: "3A382F", dark: "ECE8DC")
    static let pfInkMuted = Color(light: "908C7E", dark: "9A9588")
    static let pfSectionLabel = Color(light: "A8A496", dark: "7C786C")

    // Energy / severity (green = plenty left, orange = low, red = almost dry)
    static let pfEnergyFull = Color(light: "4FC51C", dark: "62D62C")
    static let pfEnergyFullShadow = Color(light: "3DA013", dark: "2F7A0F")
    static let pfEnergyLow = Color(light: "FF9D0A", dark: "FFAE33")
    static let pfEnergyEmpty = Color(light: "FF5A5A", dark: "FF6B6B")

    // Hero surfaces + ink, by state
    static let pfHeroFullBG = Color(light: "EAF8E0", dark: "22311A")
    static let pfHeroFullBorder = Color(light: "CFEEB8", dark: "3C5A2A")
    static let pfHeroFullInk = Color(light: "2E7D12", dark: "8FE25A")
    static let pfHeroFullSub = Color(light: "5B7A3E", dark: "A6C98A")
    static let pfHeroLowBG = Color(light: "FFF1DD", dark: "332715")
    static let pfHeroLowBorder = Color(light: "FAD9A0", dark: "5A4424")
    static let pfHeroLowInk = Color(light: "B5650A", dark: "FFC368")
    static let pfHeroLowSub = Color(light: "8A6A3A", dark: "D8B488")
    static let pfHeroEmptyBG = Color(light: "FFE4E1", dark: "3A1F1E")
    static let pfHeroEmptyBorder = Color(light: "F6C0BC", dark: "5E2F2D")
    static let pfHeroEmptyInk = Color(light: "C0322E", dark: "FF9B96")
    static let pfHeroEmptySub = Color(light: "8A4B47", dark: "E0A8A4")

    // Plan badges
    static let pfPlanMaxFG = Color(light: "A24DEB", dark: "D9B3FF")
    static let pfPlanMaxBG = Color(light: "F2E6FF", dark: "3A2A50")
    static let pfPlanProFG = Color(light: "2E9E0E", dark: "7FD65A")
    static let pfPlanProBG = Color(light: "E7F8DC", dark: "23381A")
    static let pfPlanFreeFG = Color(light: "8A8676", dark: "B8B3A2")
    static let pfPlanFreeBG = Color(light: "EFECE0", dark: "33312A")
}

// MARK: - Typography
//
// Fredoka (display) + Nunito (body) per the design. Until the TTFs are bundled
// under ClaudeMeter/Fonts/ and registered via ATSApplicationFontsPath, fall back
// to SF Rounded — a close approximation. Flip `useBundled` after bundling.

enum PFont {
    /// Real Fredoka + Nunito ship in ClaudeMeter/Fonts (registered via
    /// ATSApplicationFontsPath). Flip to false to fall back to SF Rounded.
    static let useBundled = true

    /// Fredoka role: headings, numbers, avatars, plan badges.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        guard useBundled else { return .system(size: size, weight: weight, design: .rounded) }
        let face: String
        switch weight {
        case .bold, .heavy, .black: face = "Fredoka-Bold"
        case .semibold, .medium: face = "Fredoka-SemiBold"
        default: face = "Fredoka-Regular"
        }
        return .custom(face, fixedSize: size)
    }

    /// Nunito role: labels, captions, body.
    static func body(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        guard useBundled else { return .system(size: size, weight: weight) }
        let face: String
        switch weight {
        case .heavy, .black: face = "Nunito-ExtraBold"
        case .bold: face = "Nunito-Bold"
        default: face = "Nunito-SemiBold"
        }
        return .custom(face, fixedSize: size)
    }
}

// MARK: - Energy semantics

/// Display band derived from the existing usage severity. We keep `UsageThresholds`
/// (percentUsed: warning 80 / critical 95) as the single source of truth so the
/// menu-bar dot, ring colors, hero, and notifications always agree.
enum EnergyBand {
    case full, low, empty, tappedOut, unknown

    init(severity: UsageSeverity) {
        switch severity {
        case .normal: self = .full
        case .warning: self = .low
        case .critical: self = .empty
        case .overLimit: self = .tappedOut
        case .unknown: self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .full: return .pfEnergyFull
        case .low: return .pfEnergyLow
        case .empty, .tappedOut: return .pfEnergyEmpty
        case .unknown: return Color.pfInkMuted.opacity(0.45)
        }
    }

    /// Worst-of, for combining windows / accounts into one overall band.
    static func worse(_ a: EnergyBand, _ b: EnergyBand) -> EnergyBand {
        func rank(_ x: EnergyBand) -> Int {
            switch x {
            case .unknown: return 0
            case .full: return 1
            case .low: return 2
            case .empty: return 3
            case .tappedOut: return 4
            }
        }
        return rank(a) >= rank(b) ? a : b
    }
}

extension LimitWindow {
    // `percentLeft(asOf:)` now lives in ClaudeMeterCore (Models.swift) so the
    // notification engine doesn't depend on this UI layer.

    func energyBand(thresholds: UsageThresholds, asOf now: Date) -> EnergyBand {
        EnergyBand(severity: thresholds.severity(for: resolved(asOf: now).percentUsed))
    }

    /// "78% left" style string (energy remaining), or a raw count fallback.
    func leftPercentText(asOf now: Date) -> String? {
        guard let left = percentLeft(asOf: now) else { return resolved(asOf: now).rawValueText }
        let rounded = (left * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(rounded))%" }
        return String(format: "%.1f%%", rounded)
    }

    /// Ring/bar fill fraction for the chosen progression: usage *fills*, energy-left *depletes*.
    func displayFraction(usage: Bool, asOf now: Date) -> Double {
        guard let used = resolved(asOf: now).percentUsed else { return 0 }
        let clamped = min(100, max(0, used))
        return (usage ? clamped : 100 - clamped) / 100
    }

    /// The number to show for the chosen progression ("% used" or "% left").
    func displayText(usage: Bool, asOf now: Date) -> String? {
        usage ? resolved(asOf: now).displayPercent : leftPercentText(asOf: now)
    }
}

/// Flavor phrase for a per-window energy level. Finer-grained than the color
/// band — it's mood text. `kind` lets 5-hour vs weekly read a little differently.
func energyPhrase(left: Double, kind: LimitWindowKind) -> String {
    switch left {
    case 80...: return kind == .session ? "Full tank ⚡️" : "Loads left"
    case 50..<80: return kind == .session ? "Tons of energy" : "Loads left"
    case 30..<50: return "Half a tank"
    case 15..<30: return "Getting low"
    case 5..<15: return "Running low"
    default: return "Almost dry — easy now"
    }
}

// MARK: - Chunky 3D treatments

/// White card with a 2pt border and a darker bottom "lip" — the Duolingo 3D sit.
struct ChunkyCard: ViewModifier {
    var fill: Color = .pfCard
    var border: Color = .pfCardBorder
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content.background(
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.pfCardLip)
                    .offset(y: 3)
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: 2)
            }
        )
    }
}

extension View {
    func chunkyCard(fill: Color = .pfCard, border: Color = .pfCardBorder, radius: CGFloat = 18)
        -> some View
    {
        modifier(ChunkyCard(fill: fill, border: border, radius: radius))
    }
}

/// A raised, glyph-bearing rounded tile (avatars, header icon) with the inset
/// bottom press-highlight.
struct RaisedTile<Content: View>: View {
    var fill: Color
    var size: CGFloat
    var radius: CGFloat = 11
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(fill)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.14)).frame(height: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Duolingo's signature raised button: solid fill over a solid colored shadow
/// plate that compresses on press.
struct RaisedButtonStyle: ButtonStyle {
    var fill: Color = .pfEnergyFull
    var shadow: Color = .pfEnergyFullShadow
    var radius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(PFont.display(14, .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .offset(y: pressed ? 2 : 0)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(shadow)
                    .offset(y: pressed ? 2 : 4)
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
    }
}

// MARK: - Plan badge

/// Pill badge for a known plan. Only the active OAuth account carries a plan, so
/// callers pass `nil` (no badge) for statusline-only accounts.
struct PlanBadge: View {
    let plan: String

    var body: some View {
        let s = Self.style(for: plan)
        Text(s.text)
            .font(PFont.display(10, .bold))
            .foregroundStyle(s.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(s.bg))
            .fixedSize()
    }

    static func style(for plan: String) -> (fg: Color, bg: Color, text: String) {
        let p = plan.lowercased()
        if p.contains("max") { return (.pfPlanMaxFG, .pfPlanMaxBG, "MAX") }
        if p.contains("enterprise") { return (.pfPlanMaxFG, .pfPlanMaxBG, "ENTERPRISE") }
        if p.contains("team") { return (.pfPlanProFG, .pfPlanProBG, "TEAM") }
        if p.contains("pro") { return (.pfPlanProFG, .pfPlanProBG, "PRO") }
        if p.contains("free") { return (.pfPlanFreeFG, .pfPlanFreeBG, "FREE") }
        return (.pfPlanFreeFG, .pfPlanFreeBG, plan.uppercased())
    }
}

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
    static let pfInkMuted = Color(light: "6A665B", dark: "ADA798")
    static let pfSectionLabel = Color(light: "6A665B", dark: "ADA798")

    // Energy / severity (green = plenty left, orange = low, red = almost dry)
    static let pfEnergyFull = Color(light: "4FC51C", dark: "62D62C")
    static let pfAction = Color(hex: "287B12")
    static let pfActionShadow = Color(hex: "19550B")
    static let pfEnergyLow = Color(light: "FF9D0A", dark: "FFAE33")
    static let pfEnergyEmpty = Color(light: "FF5A5A", dark: "FF6B6B")

    // Text needs stronger contrast than the bright ring and bar fills.
    static let pfEnergyFullInk = Color(light: "2E7D12", dark: "8FE25A")
    static let pfEnergyLowInk = Color(light: "965000", dark: "FFC368")
    static let pfEnergyEmptyInk = Color(light: "B52C28", dark: "FF9B96")

    // Hero surfaces + ink, by state
    static let pfHeroFullBG = Color(light: "EAF8E0", dark: "22311A")
    static let pfHeroFullBorder = Color(light: "CFEEB8", dark: "3C5A2A")
    static let pfHeroFullInk = Color(light: "2E7D12", dark: "8FE25A")
    static let pfHeroFullSub = Color(light: "547236", dark: "A6C98A")
    static let pfHeroLowBG = Color(light: "FFF1DD", dark: "332715")
    static let pfHeroLowBorder = Color(light: "FAD9A0", dark: "5A4424")
    static let pfHeroLowInk = Color(light: "965000", dark: "FFC368")
    static let pfHeroLowSub = Color(light: "8A6A3A", dark: "D8B488")
    static let pfHeroEmptyBG = Color(light: "FFE4E1", dark: "3A1F1E")
    static let pfHeroEmptyBorder = Color(light: "F6C0BC", dark: "5E2F2D")
    static let pfHeroEmptyInk = Color(light: "C0322E", dark: "FF9B96")
    static let pfHeroEmptySub = Color(light: "8A4B47", dark: "E0A8A4")

    // Plan badges
    static let pfPlanMaxFG = Color(light: "8133BC", dark: "D9B3FF")
    static let pfPlanMaxBG = Color(light: "F2E6FF", dark: "3A2A50")
    static let pfPlanProFG = Color(light: "287B12", dark: "7FD65A")
    static let pfPlanProBG = Color(light: "E7F8DC", dark: "23381A")
    static let pfPlanFreeFG = Color(light: "6F6A5B", dark: "B8B3A2")
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
/// menu-bar dot, ring colors, and hero always agree.
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

    var ink: Color {
        switch self {
        case .full: .pfEnergyFullInk
        case .low: .pfEnergyLowInk
        case .empty, .tappedOut: .pfEnergyEmptyInk
        case .unknown: .pfInkMuted
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
        guard let clamped = resolved(asOf: now).clampedPercent else { return 0 }
        return (usage ? clamped : 100 - clamped) / 100
    }

    /// The number to show for the chosen progression ("% used" or "% left").
    func displayText(usage: Bool, asOf now: Date) -> String? {
        usage ? resolved(asOf: now).displayPercent : leftPercentText(asOf: now)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.isEnabled) private var isEnabled

    var fill: Color = .pfAction
    var shadow: Color = .pfActionShadow
    var radius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(PFont.display(14, .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            // Horizontal padding must be *inside* the flexible frame. Without it
            // the pill had no side inset at all, and a `.fixedSize()` caller — the
            // status states all use one — collapsed it to exactly the text width,
            // so the label sat flush against both edges.
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .offset(y: pressed ? 2 : 0)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(shadow)
                    .offset(y: pressed ? 2 : 4)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .animation(
                reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.6),
                value: pressed)
    }
}

/// Shared feedback for compact controls. Native buttons retain keyboard focus.
struct QuietButtonStyle: ButtonStyle {
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, radius: radius)
    }

    private struct QuietButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(
                            Color.pfInk.opacity(
                                isEnabled && configuration.isPressed
                                    ? 0.12 : (isEnabled && isHovered ? 0.06 : 0)))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(isFocused ? Color.pfHeroFullInk : .clear, lineWidth: 2)
                }
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Plan badge

/// Pill badge for a known provider plan.
struct PlanBadge: View {
    let plan: String
    /// Show the plan exactly as its provider names it instead of normalizing to
    /// Claude's tier vocabulary. Codex distinguishes "Pro 5X" from "Pro 20X" and
    /// has tiers Claude doesn't (Plus, Go, Business) — collapsing those to "PRO"
    /// would state something false about the account.
    var verbatim: Bool = false

    var body: some View {
        let s = Self.style(for: plan)
        Text(verbatim ? plan.uppercased() : s.text)
            .font(PFont.display(10, .bold))
            .foregroundStyle(s.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(s.bg))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(plan)
    }

    static func style(for plan: String) -> (fg: Color, bg: Color, text: String) {
        let p = plan.lowercased()
        if p.contains("max") { return (.pfPlanMaxFG, .pfPlanMaxBG, "MAX") }
        if p.contains("enterprise") { return (.pfPlanMaxFG, .pfPlanMaxBG, "ENTERPRISE") }
        if p.contains("team") { return (.pfPlanProFG, .pfPlanProBG, "TEAM") }
        if p.contains("business") { return (.pfPlanProFG, .pfPlanProBG, "BUSINESS") }
        if p == "pro 5x" || p == "pro 20x" {
            return (.pfPlanProFG, .pfPlanProBG, plan.uppercased())
        }
        if p.contains("pro") { return (.pfPlanProFG, .pfPlanProBG, "PRO") }
        // Codex tiers with no Claude equivalent; paid, so they take the Pro
        // palette but keep their own label. `go` is matched exactly rather than
        // by substring — "go" appears inside plenty of words, and plan strings
        // can be arbitrary user-typed overrides (`MeterSettings.accountPlans`).
        if p.contains("plus") { return (.pfPlanProFG, .pfPlanProBG, "PLUS") }
        if p == "go" { return (.pfPlanProFG, .pfPlanProBG, "GO") }
        if p.contains("free") { return (.pfPlanFreeFG, .pfPlanFreeBG, "FREE") }
        return (.pfPlanFreeFG, .pfPlanFreeBG, plan.uppercased())
    }
}

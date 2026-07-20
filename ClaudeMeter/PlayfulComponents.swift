import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI

// MARK: - Activity rings
//
// Two concentric *depleting* rings: outer = weekly (r34), inner = 5-hour (r24),
// 8pt round-cap stroke, starting at the top. The arc length is energy REMAINING
// (`percentLeft`), so a full ring = a full tank. Center holds the avatar letter.

struct ActivityRingsView: View {
    var weeklyFraction: Double  // 0…1 energy left (outer)
    var weeklyColor: Color
    var sessionFraction: Double  // 0…1 energy left (inner)
    var sessionColor: Color
    var letter: String
    var size: CGFloat = 88

    var body: some View {
        ZStack {
            DepletingRing(
                fraction: weeklyFraction, color: weeklyColor,
                diameter: size * (68.0 / 88.0), lineWidth: size * (8.0 / 88.0))
            DepletingRing(
                fraction: sessionFraction, color: sessionColor,
                diameter: size * (48.0 / 88.0), lineWidth: size * (8.0 / 88.0))
            Text(letter)
                .font(PFont.display(size * (19.0 / 88.0), .bold))
                .foregroundStyle(Color.pfInk)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct DepletingRing: View {
    var fraction: Double
    var color: Color
    var diameter: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.pfTrack, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: fraction)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The little 9×9 rounded-square status pip used in the metric rows.
struct EnergyDot: View {
    var color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: 9, height: 9)
    }
}

/// A chunky horizontal energy bar (fills or depletes depending on the fraction
/// passed) with an inner top gloss.
struct EnergyBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.pfTrack)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
                    .overlay(alignment: .top) {
                        Capsule().fill(Color.white.opacity(0.45))
                            .frame(height: 2).padding(.horizontal, 3).padding(.top, 2)
                    }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.5), value: fraction)
    }
}

/// Chunky, color-coded threshold slider: thick track + a big white ring-thumb.
/// Built by hand because the native `Slider` can't do the ringed thumb.
struct ColorSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var color: Color

    private let thumb: CGFloat = 26
    private let track: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let span = max(1, geo.size.width - thumb)
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = CGFloat(min(1, max(0, frac))) * span
            ZStack(alignment: .leading) {
                Capsule().fill(Color.pfTrack).frame(height: track)
                Capsule().fill(color).frame(width: x + thumb / 2, height: track)
                Circle()
                    .fill(Color.pfCard)
                    .overlay(Circle().strokeBorder(color, lineWidth: 4))
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(height: thumb)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(1, max(0, (g.location.x - thumb / 2) / span))
                        let raw =
                            range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        let stepped = (raw / step).rounded() * step
                        value = min(range.upperBound, max(range.lowerBound, stepped))
                    }
            )
        }
        .frame(height: thumb)
    }
}

/// Legend for the ACCOUNTS section header (rings variant).
struct RingLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle().strokeBorder(Color.pfInkMuted, lineWidth: 2.5).frame(width: 9, height: 9)
                Text("weekly").font(PFont.body(10, .bold)).foregroundStyle(Color.pfInkMuted)
            }
            HStack(spacing: 4) {
                Circle().fill(Color.pfInkMuted).frame(width: 9, height: 9)
                Text("5-hour").font(PFont.body(10, .bold)).foregroundStyle(Color.pfInkMuted)
            }
        }
    }
}

// MARK: - Per-account card model
//
// Unified shape the popover builds from either `snapshot.accounts` (multi) or the
// top-level snapshot (single). Email/plan/opus are present only for the active
// OAuth account; the card degrades gracefully when they're nil.

struct AccountCardModel: Identifiable {
    var id: String
    var label: String
    var plan: String?
    var subtitle: String?  // email, else nil
    var session: LimitWindow
    var week: LimitWindow
    var opus: LimitWindow?
    /// Scoped weekly windows (`seven_day_sonnet`, …) — display-only rows below
    /// Opus; they don't influence the card's band or the reset summary.
    var scoped: [ScopedLimitWindow] = []
    /// Another account shares this one's organization id — same login, one
    /// quota shown twice (see `MultiAccountOAuth.duplicateOrgAccountKeys`).
    var isDuplicateLogin: Bool = false
    /// A Claude Code session is open for this account right now (fresh
    /// statusline bridge + active account). "Open", not "burning tokens" —
    /// the bridge rewrites session files once a second even while idle.
    var isLive: Bool = false

    var avatarLetter: String {
        let trimmed = label.drop(while: { !$0.isLetter && !$0.isNumber })
        return String(trimmed.first ?? Character("C")).uppercased()
    }

    var avatarColor: Color { avatarColorForID(id) }

    func band(_ thresholds: UsageThresholds, _ now: Date) -> EnergyBand {
        var b = session.energyBand(thresholds: thresholds, asOf: now)
        b = EnergyBand.worse(b, week.energyBand(thresholds: thresholds, asOf: now))
        if let opus { b = EnergyBand.worse(b, opus.energyBand(thresholds: thresholds, asOf: now)) }
        return b
    }

    func minLeft(_ now: Date) -> Double {
        [session.percentLeft(asOf: now), week.percentLeft(asOf: now), opus?.percentLeft(asOf: now)]
            .compactMap { $0 }.min() ?? 100
    }

    /// Soonest upcoming refill/reset across this account's windows.
    func soonestReset(_ now: Date) -> Date? {
        [session.resolved(asOf: now).resetsAt,
         week.resolved(asOf: now).resetsAt,
         opus?.resolved(asOf: now).resetsAt]
            .compactMap { $0 }.filter { $0 > now }.min()
    }
}

private let pfAvatarPalette: [Color] = [
    Color(hex: "25B6F0"), Color(hex: "C77DFF"), Color(hex: "FF9D0A"),
    Color(hex: "4FC51C"), Color(hex: "FF7AA8"), Color(hex: "2DD4BF"),
    Color(hex: "7C83FF"), Color(hex: "F4B400"),
]

/// Stable, fun avatar color derived from the account id (djb2).
func avatarColorForID(_ id: String) -> Color {
    var h = 5381
    for b in id.utf8 { h = (h &* 33) &+ Int(b) }
    let n = pfAvatarPalette.count
    return pfAvatarPalette[((h % n) + n) % n]
}

/// Whether the popover window is actually on screen. The MenuBarExtra `.window`
/// popover view is retained (hidden) across dismissals, and `TimelineView`
/// animations keep ticking at display refresh rate in the hidden window —
/// re-laying-out the whole hierarchy every frame (~20% CPU). Every continuous
/// animation inside the popover must pause on this flag.
private struct PopoverVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var popoverIsVisible: Bool {
        get { self[PopoverVisibleKey.self] }
        set { self[PopoverVisibleKey.self] = newValue }
    }
}

/// Pulsing "session open now" marker on the active account's card; static when
/// Reduce Motion is on.
struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.popoverIsVisible) private var popoverIsVisible

    var body: some View {
        Group {
            if reduceMotion {
                Circle().fill(Color.pfEnergyFull).frame(width: 7, height: 7)
            } else {
                // 12 fps is plenty for a 1.6 s opacity pulse; paused entirely
                // while the popover window is hidden.
                TimelineView(.animation(minimumInterval: 1 / 12, paused: !popoverIsVisible)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (sin(t * 2 * .pi / 1.6) + 1) / 2  // 0…1 over 1.6s
                    Circle()
                        .fill(Color.pfEnergyFull)
                        .frame(width: 7, height: 7)
                        .opacity(0.55 + 0.45 * phase)
                }
            }
        }
        .accessibilityLabel("Session open")
        .help("A Claude Code session is open for this account right now.")
    }
}

/// Chip flagging that two config dirs are logged into the same Claude account
/// (their windows are one shared quota rendered twice).
struct DuplicateLoginBadge: View {
    var body: some View {
        Text("same login")
            .font(PFont.body(9, .bold))
            .foregroundStyle(Color.pfInkMuted)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.pfTrack))
            .help(
                "Two config dirs are logged into the same Claude account — they share one quota.")
    }
}

// MARK: - Account ring card

struct AccountRingCard: View {
    let model: AccountCardModel
    let now: Date
    var thresholds: UsageThresholds = .default
    /// `true` shows usage (rings fill); `false` shows energy left (rings deplete).
    var usage: Bool = false

    var body: some View {
        let sBand = model.session.energyBand(thresholds: thresholds, asOf: now)
        let wBand = model.week.energyBand(thresholds: thresholds, asOf: now)
        HStack(spacing: 14) {
            ActivityRingsView(
                weeklyFraction: fraction(model.week),
                weeklyColor: wBand.color,
                sessionFraction: fraction(model.session),
                sessionColor: sBand.color,
                letter: model.avatarLetter
            )
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.label)
                        .font(PFont.display(15, .semibold))
                        .foregroundStyle(Color.pfInk)
                        .lineLimit(1)
                    if model.isLive { LiveDot() }
                    Spacer(minLength: 4)
                    if model.isDuplicateLogin { DuplicateLoginBadge() }
                    if let plan = model.plan { PlanBadge(plan: plan) }
                }
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(PFont.body(11, .bold))
                        .foregroundStyle(Color.pfInkMuted)
                        .lineLimit(1)
                }
                metricRow("5-hr", window: model.session, band: sBand, kind: .session)
                metricRow("week", window: model.week, band: wBand, kind: .weekly)
                if let opus = model.opus {
                    let oBand = opus.energyBand(thresholds: thresholds, asOf: now)
                    metricRow("opus", window: opus, band: oBand, kind: .weekly)
                }
                ForEach(model.scoped) { scoped in
                    metricRow(
                        scoped.displayName.lowercased(), window: scoped.window,
                        band: scoped.window.energyBand(thresholds: thresholds, asOf: now),
                        kind: .weekly)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func fraction(_ window: LimitWindow) -> Double {
        window.displayFraction(usage: usage, asOf: now)
    }

    @ViewBuilder
    private func metricRow(
        _ label: String, window: LimitWindow, band: EnergyBand, kind: LimitWindowKind
    ) -> some View {
        HStack(spacing: 6) {
            EnergyDot(color: band.color)
            Text(label)
                .font(PFont.body(11, .bold))
                .foregroundStyle(Color.pfInk)
            Text(window.displayText(usage: usage, asOf: now) ?? "—")
                .font(PFont.display(11, .heavy))
                .foregroundStyle(window.percentLeft(asOf: now) == nil ? Color.pfInkMuted : band.color)
                .monospacedDigit()
            if let detail = resetDetail(window, kind: kind) {
                Text("· \(detail)")
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    private func resetDetail(_ window: LimitWindow, kind: LimitWindowKind) -> String? {
        guard let resetsAt = window.resolved(asOf: now).resetsAt else { return nil }
        return ResetPhrase.spoken(until: resetsAt, asOf: now)
    }

    private var accessibilityText: String {
        let s = model.session.leftPercentText(asOf: now) ?? "unknown"
        let w = model.week.leftPercentText(asOf: now) ?? "unknown"
        return "\(model.label): 5-hour \(s) left, weekly \(w) left"
    }
}

// MARK: - Account bar card (energy-bar variant)

struct AccountBarCard: View {
    let model: AccountCardModel
    let now: Date
    var thresholds: UsageThresholds = .default
    var usage: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RaisedTile(fill: model.avatarColor, size: 38, radius: 11) {
                    Text(model.avatarLetter).font(PFont.display(17, .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(model.label)
                            .font(PFont.display(15, .semibold)).foregroundStyle(Color.pfInk)
                            .lineLimit(1)
                        if model.isLive { LiveDot() }
                    }
                    if let subtitle = model.subtitle {
                        Text(subtitle)
                            .font(PFont.body(11, .bold)).foregroundStyle(Color.pfInkMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if model.isDuplicateLogin { DuplicateLoginBadge() }
                if let plan = model.plan { PlanBadge(plan: plan) }
            }
            barSection("5-Hour Energy", icon: "⚡️", window: model.session, kind: .session)
            barSection("Weekly Fuel", icon: "📅", window: model.week, kind: .weekly)
            if let opus = model.opus {
                barSection("Weekly Opus", icon: "🧠", window: opus, kind: .weekly)
            }
            ForEach(model.scoped) { scoped in
                barSection(
                    "Weekly \(scoped.displayName)", icon: "📊", window: scoped.window,
                    kind: .weekly)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func barSection(
        _ label: String, icon: String, window: LimitWindow, kind: LimitWindowKind
    ) -> some View {
        let band = window.energyBand(thresholds: thresholds, asOf: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(icon).font(.system(size: 13))
                Text(label).font(PFont.body(13, .bold)).foregroundStyle(Color.pfInk)
                Spacer(minLength: 4)
                Text(window.displayText(usage: usage, asOf: now) ?? "—")
                    .font(PFont.display(14, .bold)).foregroundStyle(band.color).monospacedDigit()
                Text(usage ? "used" : "left")
                    .font(PFont.body(12, .bold)).foregroundStyle(Color.pfInkMuted)
            }
            EnergyBar(fraction: window.displayFraction(usage: usage, asOf: now), color: band.color)
            HStack {
                Text(energyPhrase(left: window.percentLeft(asOf: now) ?? 0, kind: kind))
                    .font(PFont.body(11, .bold)).foregroundStyle(band.color)
                Spacer(minLength: 4)
                if let reset = resetText(window, kind: kind) {
                    Text(reset)
                        .font(PFont.body(11, .semibold)).foregroundStyle(Color.pfInkMuted)
                        .monospacedDigit()
                }
            }
        }
    }

    private func resetText(_ window: LimitWindow, kind: LimitWindowKind) -> String? {
        guard let date = window.resolved(asOf: now).resetsAt,
            let phrase = ResetPhrase.spoken(until: date, asOf: now)
        else { return nil }
        return kind == .session ? "Refills \(phrase)" : "Resets \(phrase)"
    }
}

// MARK: - Hero (combined health)

/// The hero reflects the *active* account's vibe (the one you're using), with a
/// subtitle that flags the lowest other account. The menu-bar dot, by contrast,
/// mirrors the nearest-limit account across all of them.
struct HeroSummary {
    var emoji: String
    var title: String
    var subtitle: String
    var bg: Color
    var border: Color
    var ink: Color
    var sub: Color

    static func make(models: [AccountCardModel], thresholds: UsageThresholds, now: Date)
        -> HeroSummary
    {
        let active = models.first
        let band = active?.band(thresholds, now) ?? .unknown
        let palette = paletteFor(band)
        let (emoji, title) = headlineFor(band)
        let subtitle = subtitleFor(models: models, thresholds: thresholds, now: now)
        return HeroSummary(
            emoji: emoji, title: title, subtitle: subtitle,
            bg: palette.bg, border: palette.border, ink: palette.ink, sub: palette.sub)
    }

    private static func headlineFor(_ band: EnergyBand) -> (String, String) {
        switch band {
        case .full: return ("🚀", "You're cruising")
        case .low: return ("⛽️", "Pace yourself")
        case .empty: return ("🪫", "Almost tapped out")
        case .tappedOut: return ("🥵", "Take a breather")
        case .unknown: return ("🛰️", "Warming up")
        }
    }

    private static func subtitleFor(
        models: [AccountCardModel], thresholds: UsageThresholds, now: Date
    ) -> String {
        guard let active = models.first else { return "No usage yet — fire up Claude Code." }

        // Single account → speak to its own most-constrained window.
        if models.count == 1 {
            let band = active.band(thresholds, now)
            let when = active.soonestReset(now).map { describeReset($0, now: now) }
            switch band {
            case .full: return when.map { "Plenty in the tank · refills \($0)" } ?? "Plenty in the tank 🎉"
            case .low: return when.map { "Getting low · refills \($0)" } ?? "Getting low"
            case .empty, .tappedOut: return when.map { "Almost dry · refills \($0)" } ?? "Almost dry"
            case .unknown: return "Warming up…"
            }
        }

        // Multi account → count fresh + flag the lowest non-full account.
        let fresh = models.filter { $0.band(thresholds, now) == .full }.count
        let lowest = models
            .filter { $0.band(thresholds, now) != .full && $0.band(thresholds, now) != .unknown }
            .min(by: { $0.minLeft(now) < $1.minLeft(now) })
        if let low = lowest {
            let word = low.band(thresholds, now) == .low ? "low" : "nearly dry"
            let refill = low.soonestReset(now)
                .map { " (\(ResetPhrase.duration(until: $0, asOf: now) ?? "soon"))" } ?? ""
            if fresh == 0 { return "\(low.label) is \(word)\(refill)" }
            let freshWord = fresh == 1 ? "1 fresh" : "\(fresh) fresh"
            return "\(freshWord) · \(low.label) \(word)\(refill)"
        }
        return "All \(models.count) accounts fresh 🎉"
    }

    private struct Palette {
        var bg: Color
        var border: Color
        var ink: Color
        var sub: Color
    }

    private static func paletteFor(_ band: EnergyBand) -> Palette {
        switch band {
        case .full, .unknown:
            return Palette(
                bg: .pfHeroFullBG, border: .pfHeroFullBorder, ink: .pfHeroFullInk, sub: .pfHeroFullSub)
        case .low:
            return Palette(
                bg: .pfHeroLowBG, border: .pfHeroLowBorder, ink: .pfHeroLowInk, sub: .pfHeroLowSub)
        case .empty, .tappedOut:
            return Palette(
                bg: .pfHeroEmptyBG, border: .pfHeroEmptyBorder, ink: .pfHeroEmptyInk,
                sub: .pfHeroEmptySub)
        }
    }
}

struct HeroView: View {
    let summary: HeroSummary

    var body: some View {
        HStack(spacing: 12) {
            Text(summary.emoji)
                .font(.system(size: 24))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.pfCard))
                .overlay(Circle().strokeBorder(summary.border, lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(PFont.display(18, .semibold))
                    .foregroundStyle(summary.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(summary.subtitle)
                    .font(PFont.body(12, .bold))
                    .foregroundStyle(summary.sub)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.pfCardLip)
                    .offset(y: 3)
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(summary.bg)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(summary.border, lineWidth: 2)
            }
        )
        .animation(.easeInOut(duration: 0.3), value: summary.bg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.title). \(summary.subtitle)")
    }
}

// MARK: - Shared reset wording

/// "in 3h 12m" / "in 36h" / "in 4 days" — the app-wide `ResetPhrase` rule.
func describeReset(_ date: Date, now: Date) -> String {
    ResetPhrase.spoken(until: date, asOf: now) ?? "soon"
}

// MARK: - Activity heatmap grid (GitHub-style punchcard)

/// A 7×24 grid (Mon–Sun rows × hour-of-day columns) shaded by message volume,
/// relative to the busiest cell. Cells stretch to fill the popover width.
struct ActivityHeatmapGrid: View {
    let map: ActivityHeatmap

    private static let weekdayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let labelWidth: CGFloat = 22
    private static let cellSpacing: CGFloat = 2
    private static let cellHeight: CGFloat = 12

    var body: some View {
        let peak = max(map.peak, 1)
        VStack(spacing: Self.cellSpacing) {
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: Self.cellSpacing) {
                    Text(Self.weekdayLabels[day])
                        .font(PFont.body(9, .bold))
                        .foregroundStyle(Color.pfInkMuted)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Self.color(for: map.counts[day][hour], peak: peak))
                            .frame(maxWidth: .infinity)
                            .frame(height: Self.cellHeight)
                    }
                }
            }
            // Hour axis: label every 6 hours.
            HStack(spacing: Self.cellSpacing) {
                Spacer().frame(width: Self.labelWidth)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour)" : "")
                        .font(PFont.body(8, .semibold))
                        .foregroundStyle(Color.pfInkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Shade for an absolute count, bucketed into 5 levels relative to `peak`.
    static func color(for count: Int, peak: Int) -> Color {
        guard count > 0 else { return color(forLevel: 0) }
        let frac = Double(count) / Double(max(peak, 1))
        let level = frac >= 0.75 ? 4 : frac >= 0.5 ? 3 : frac >= 0.25 ? 2 : 1
        return color(forLevel: level)
    }

    static func color(forLevel level: Int) -> Color {
        switch level {
        case 0: return Color.pfTrack
        case 1: return Color.pfEnergyFull.opacity(0.28)
        case 2: return Color.pfEnergyFull.opacity(0.5)
        case 3: return Color.pfEnergyFull.opacity(0.75)
        default: return Color.pfEnergyFull
        }
    }
}

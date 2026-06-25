import AppKit
import ClaudeMeterCore
import SwiftUI
import WidgetKit

// MARK: - Design tokens (local to widget target — intentionally not shared)

extension Color {
    fileprivate init(widgetHex string: String) {
        var str = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        var hex: UInt64 = 0
        Scanner(string: str).scanHexInt64(&hex)
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }

    /// Appearance-adaptive widget color (light vs. dark).
    fileprivate init(widgetLight l: String, dark d: String) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(Color(widgetHex: isDark ? d : l))
            })
    }

    fileprivate static let wPopover = Color(widgetLight: "FBF9F2", dark: "201E18")
    fileprivate static let wCard = Color(widgetLight: "FFFFFF", dark: "2A2820")
    fileprivate static let wCardBorder = Color(widgetLight: "EFEAD9", dark: "3D3A30")
    fileprivate static let wTrack = Color(widgetLight: "ECE9DD", dark: "3A372E")
    fileprivate static let wInk = Color(widgetLight: "3A382F", dark: "ECE8DC")
    fileprivate static let wInkMuted = Color(widgetLight: "908C7E", dark: "9A9588")
    fileprivate static let wFull = Color(widgetLight: "4FC51C", dark: "62D62C")
    fileprivate static let wLow = Color(widgetLight: "FF9D0A", dark: "FFAE33")
    fileprivate static let wEmpty = Color(widgetLight: "FF5A5A", dark: "FF6B6B")
}

private func energyColor(percentUsed: Double?, thresholds: UsageThresholds) -> Color {
    switch thresholds.severity(for: percentUsed) {
    case .normal: return .wFull
    case .warning: return .wLow
    case .critical, .overLimit: return .wEmpty
    case .unknown: return Color.wInkMuted.opacity(0.5)
    }
}

private func percentLeft(_ window: LimitWindow, asOf now: Date) -> Double? {
    guard let used = window.resolved(asOf: now).percentUsed else { return nil }
    return 100 - min(100, max(0, used))
}

private func leftText(_ window: LimitWindow, asOf now: Date) -> String {
    guard let left = percentLeft(window, asOf: now) else { return "—" }
    return "\(Int(left.rounded()))%"
}

// MARK: - Typography (Fredoka/Nunito bundled into the widget target too)

private enum WFont {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        let face: String
        switch weight {
        case .bold, .heavy, .black: face = "Fredoka-Bold"
        case .semibold, .medium: face = "Fredoka-SemiBold"
        default: face = "Fredoka-Regular"
        }
        return .custom(face, fixedSize: size)
    }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let face: String
        switch weight {
        case .heavy, .black: face = "Nunito-ExtraBold"
        case .bold: face = "Nunito-Bold"
        default: face = "Nunito-SemiBold"
        }
        return .custom(face, fixedSize: size)
    }
}

// MARK: - Entry

struct ClaudeMeterEntry: TimelineEntry {
    let date: Date
    let snapshot: ClaudeUsageSnapshot?
    let thresholds: UsageThresholds
    let isStale: Bool

    init(
        date: Date,
        snapshot: ClaudeUsageSnapshot?,
        thresholds: UsageThresholds = .default,
        isStale: Bool = false
    ) {
        self.date = date
        self.snapshot = snapshot
        self.thresholds = thresholds
        self.isStale = isStale
    }
}

// MARK: - Provider

struct ClaudeMeterProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeMeterEntry {
        ClaudeMeterEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeMeterEntry) -> Void) {
        completion(makeEntry(at: Date()))
    }

    func getTimeline(
        in context: Context, completion: @escaping (Timeline<ClaudeMeterEntry>) -> Void
    ) {
        let now = Date()
        let entry = makeEntry(at: now)

        let nextReset = [
            entry.snapshot?.limits.currentSession.resetsAt,
            entry.snapshot?.limits.currentWeekAllModels.resetsAt,
            entry.snapshot?.limits.currentWeekOpus?.resetsAt,
        ]
        .compactMap { $0 }
        .filter { $0 > now }
        .min()

        let refreshAt =
            [nextReset, now.addingTimeInterval(900)]
            .compactMap { $0 }
            .min() ?? now.addingTimeInterval(900)

        completion(Timeline(entries: [entry], policy: .after(refreshAt)))
    }

    private func makeEntry(at date: Date) -> ClaudeMeterEntry {
        let snapshot = loadSnapshot()
        return ClaudeMeterEntry(
            date: date,
            snapshot: snapshot,
            thresholds: AppGroupConfig.currentThresholds(),
            isStale: AppGroupConfig.isSnapshotStale(
                lastPollAt: snapshot?.lastSuccessfulPollAt, now: date)
        )
    }

    private func loadSnapshot() -> ClaudeUsageSnapshot? {
        guard let store = try? SnapshotStore.appGroup(suiteName: AppGroupConfig.suiteName) else {
            return nil
        }
        return try? store.readLatest()
    }
}

// MARK: - Widget configuration

@main
struct ClaudeMeterWidget: Widget {
    let kind = "ClaudeMeterWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeMeterProvider()) { entry in
            ClaudeMeterWidgetEntryView(entry: entry)
                .containerBackground(Color.wPopover, for: .widget)
        }
        .configurationDisplayName("Claude Meter")
        .description("Your Claude energy at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Entry view router

struct ClaudeMeterWidgetEntryView: View {
    let entry: ClaudeMeterEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: SmallWidgetView(entry: entry)
        case .systemMedium: MediumWidgetView(entry: entry)
        default: LargeWidgetView(entry: entry)
        }
    }
}

// MARK: - Activity rings (local copy)

private struct WidgetRings: View {
    var weekFraction: Double
    var weekColor: Color
    var sessionFraction: Double
    var sessionColor: Color
    var centerText: String
    var size: CGFloat

    var body: some View {
        ZStack {
            ring(weekFraction, weekColor, diameter: size * (68.0 / 88.0))
            ring(sessionFraction, sessionColor, diameter: size * (48.0 / 88.0))
            Text(centerText)
                .font(WFont.display(size * (20.0 / 88.0), .heavy))
                .foregroundStyle(Color.wInk)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
    }

    private func ring(_ fraction: Double, _ color: Color, diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.wTrack, lineWidth: size * (8.0 / 88.0))
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: size * (8.0 / 88.0), lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

private func ringsBlock(_ snap: ClaudeUsageSnapshot, _ entry: ClaudeMeterEntry, size: CGFloat)
    -> WidgetRings
{
    let now = entry.date
    let session = snap.limits.currentSession
    let week = snap.limits.currentWeekAllModels
    let nearest = [percentLeft(session, asOf: now), percentLeft(week, asOf: now)]
        .compactMap { $0 }.min()
    return WidgetRings(
        weekFraction: (percentLeft(week, asOf: now) ?? 0) / 100,
        weekColor: energyColor(percentUsed: week.resolved(asOf: now).percentUsed, thresholds: entry.thresholds),
        sessionFraction: (percentLeft(session, asOf: now) ?? 0) / 100,
        sessionColor: energyColor(percentUsed: session.resolved(asOf: now).percentUsed, thresholds: entry.thresholds),
        centerText: nearest.map { "\(Int($0.rounded()))" } ?? "—",
        size: size)
}

// MARK: - Energy rows

private struct EnergyRow: View {
    let label: String
    let window: LimitWindow
    let thresholds: UsageThresholds
    let referenceDate: Date
    var showReset = true

    var body: some View {
        let color = energyColor(
            percentUsed: window.resolved(asOf: referenceDate).percentUsed, thresholds: thresholds)
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color).frame(width: 9, height: 9)
            Text(label)
                .font(WFont.body(12, .bold))
                .foregroundStyle(Color.wInk)
            Text(leftText(window, asOf: referenceDate))
                .font(WFont.display(12, .heavy))
                .foregroundStyle(color)
                .monospacedDigit()
            if showReset, let detail = resetDetail {
                Text("· \(detail)")
                    .font(WFont.body(11, .semibold))
                    .foregroundStyle(Color.wInkMuted)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private var resetDetail: String? {
        guard let date = window.resolved(asOf: referenceDate).resetsAt, date > referenceDate else {
            return nil
        }
        let diff = date.timeIntervalSince(referenceDate)
        if diff >= 24 * 3600 { return Self.weekdayFormatter.string(from: date) }
        let h = Int(diff / 3600)
        let m = Int(diff.truncatingRemainder(dividingBy: 3600) / 60)
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

private struct WidgetHeader: View {
    let entry: ClaudeMeterEntry
    var showUpdated = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.wFull)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            Text("Claude Meter")
                .font(WFont.display(13, .semibold))
                .foregroundStyle(Color.wInk)
            Spacer()
            if entry.isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.wLow)
            } else if showUpdated, let pollAt = entry.snapshot?.lastSuccessfulPollAt {
                let diff = Int(entry.date.timeIntervalSince(pollAt))
                Text(diff < 60 ? "Updated \(max(0, diff))s ago" : "Updated \(diff / 60)m ago")
                    .font(WFont.body(10, .semibold))
                    .foregroundStyle(Color.wInkMuted)
            }
        }
    }
}

// MARK: - Small

private struct SmallWidgetView: View {
    let entry: ClaudeMeterEntry

    var body: some View {
        if let snap = entry.snapshot {
            VStack(spacing: 8) {
                ringsBlock(snap, entry, size: 78)
                VStack(spacing: 3) {
                    EnergyRow(
                        label: "5-hr", window: snap.limits.currentSession,
                        thresholds: entry.thresholds, referenceDate: entry.date, showReset: false)
                    EnergyRow(
                        label: "week", window: snap.limits.currentWeekAllModels,
                        thresholds: entry.thresholds, referenceDate: entry.date, showReset: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NoDataView(compact: true)
        }
    }
}

// MARK: - Medium

private struct MediumWidgetView: View {
    let entry: ClaudeMeterEntry

    var body: some View {
        if let snap = entry.snapshot {
            HStack(spacing: 16) {
                ringsBlock(snap, entry, size: 96)
                VStack(alignment: .leading, spacing: 7) {
                    WidgetHeader(entry: entry)
                    EnergyRow(
                        label: "5-hr", window: snap.limits.currentSession,
                        thresholds: entry.thresholds, referenceDate: entry.date)
                    EnergyRow(
                        label: "week", window: snap.limits.currentWeekAllModels,
                        thresholds: entry.thresholds, referenceDate: entry.date)
                    if let opus = snap.limits.currentWeekOpus {
                        EnergyRow(
                            label: "opus", window: opus, thresholds: entry.thresholds,
                            referenceDate: entry.date)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NoDataView(compact: false)
        }
    }
}

// MARK: - Large

private struct LargeWidgetView: View {
    let entry: ClaudeMeterEntry

    var body: some View {
        if let snap = entry.snapshot {
            VStack(alignment: .leading, spacing: 16) {
                WidgetHeader(entry: entry, showUpdated: true)
                HStack(spacing: 18) {
                    ringsBlock(snap, entry, size: 120)
                    VStack(alignment: .leading, spacing: 10) {
                        EnergyRow(
                            label: "5-hr", window: snap.limits.currentSession,
                            thresholds: entry.thresholds, referenceDate: entry.date)
                        EnergyRow(
                            label: "week", window: snap.limits.currentWeekAllModels,
                            thresholds: entry.thresholds, referenceDate: entry.date)
                        if let opus = snap.limits.currentWeekOpus {
                            EnergyRow(
                                label: "opus", window: opus, thresholds: entry.thresholds,
                                referenceDate: entry.date)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            NoDataView(compact: false)
        }
    }
}

// MARK: - No data

private struct NoDataView: View {
    var compact: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text("🪫").font(.system(size: compact ? 26 : 32))
            Text("No usage yet")
                .font(WFont.display(compact ? 11 : 13, .semibold))
                .foregroundStyle(Color.wInk)
            if !compact {
                Text("Open Claude Meter to start polling.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.wInkMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    ClaudeMeterWidget()
} timeline: {
    ClaudeMeterEntry(
        date: Date(),
        snapshot: ClaudeUsageSnapshot(
            parserVersion: "0.1.0",
            createdAt: Date(),
            lastSuccessfulPollAt: Date(),
            source: SourceInfo(cliPath: "/opt/homebrew/bin/claude", command: "claude status"),
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 22, resetsAt: Date().addingTimeInterval(2700)),
                currentWeekAllModels: LimitWindow(
                    percentUsed: 36, resetsAt: Date().addingTimeInterval(5 * 86400)),
                currentWeekOpus: LimitWindow(
                    percentUsed: 58, resetsAt: Date().addingTimeInterval(5 * 86400))
            ),
            state: SnapshotState(status: .ok, severity: .normal)
        )
    )
}

import WidgetKit
import SwiftUI
import ClaudeMeterCore

// MARK: - Design tokens (local to widget target)

private extension Color {
    init(widgetHex string: String) {
        var str = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        var hex: UInt64 = 0
        Scanner(string: str).scanHexInt64(&hex)
        self.init(
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8)  & 0xff) / 255,
            blue:  Double(hex          & 0xff) / 255
        )
    }

    static let cmNormal     = Color(widgetHex: "4be257")
    static let cmWarning    = Color(widgetHex: "fdbb2c")
    static let cmCritical   = Color(widgetHex: "ff5f56")
    static let cmBackground = Color(widgetHex: "10131b")
}

private func severityColor(for percent: Double?) -> Color {
    switch UsageThresholds.default.severity(for: percent) {
    case .normal:              return .cmNormal
    case .warning:             return .cmWarning
    case .critical, .overLimit: return .cmCritical
    case .unknown:             return Color.secondary
    }
}

// MARK: - Entry

struct ClaudeMeterEntry: TimelineEntry {
    let date: Date
    let snapshot: ClaudeUsageSnapshot?
}

// MARK: - Provider

struct ClaudeMeterProvider: TimelineProvider {
    private static let appGroupID = "group.com.claudemeter.app"

    func placeholder(in context: Context) -> ClaudeMeterEntry {
        ClaudeMeterEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeMeterEntry) -> Void) {
        completion(ClaudeMeterEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeMeterEntry>) -> Void) {
        let now = Date()
        let snap = loadSnapshot()
        let entry = ClaudeMeterEntry(date: now, snapshot: snap)

        // Reload at the nearest upcoming reset time, or in 15 minutes — whichever comes first.
        let nextReset = [
            snap?.limits.currentSession.resetsAt,
            snap?.limits.currentWeekAllModels.resetsAt,
        ]
        .compactMap { $0 }
        .filter { $0 > now }
        .min()

        let refreshAt = [nextReset, now.addingTimeInterval(900)]
            .compactMap { $0 }
            .min() ?? now.addingTimeInterval(900)

        completion(Timeline(entries: [entry], policy: .after(refreshAt)))
    }

    private func loadSnapshot() -> ClaudeUsageSnapshot? {
        let store: SnapshotStore
        if let s = try? SnapshotStore.appGroup(suiteName: Self.appGroupID) {
            store = s
        } else if let s = try? SnapshotStore.applicationSupport() {
            store = s
        } else {
            return nil
        }
        return (try? store.readLatest()).flatMap { $0 }
    }
}

// MARK: - Widget configuration

struct ClaudeMeterWidget: Widget {
    let kind = "ClaudeMeterWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeMeterProvider()) { entry in
            ClaudeMeterWidgetEntryView(entry: entry)
                .containerBackground(Color.cmBackground, for: .widget)
        }
        .configurationDisplayName("Claude Meter")
        .description("Monitor Claude API usage limits.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Entry view router

struct ClaudeMeterWidgetEntryView: View {
    let entry: ClaudeMeterEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:  SmallWidgetView(entry: entry)
        case .systemMedium: MediumWidgetView(entry: entry)
        default:            LargeWidgetView(entry: entry)
        }
    }
}

// MARK: - Small widget

private struct SmallWidgetView: View {
    let entry: ClaudeMeterEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Meter")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            if let snap = entry.snapshot {
                WindowRow(label: "SESSION",  window: snap.limits.currentSession)
                WindowRow(label: "WEEK",     window: snap.limits.currentWeekAllModels)
            } else {
                noDataView
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noDataView: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No data")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Medium widget

private struct MediumWidgetView: View {
    let entry: ClaudeMeterEntry

    var body: some View {
        if let snap = entry.snapshot {
            VStack(spacing: 10) {
                WindowRow(label: "SESSION",          window: snap.limits.currentSession)
                Divider().opacity(0.2)
                WindowRow(label: "WEEK (ALL MODELS)", window: snap.limits.currentWeekAllModels)
            }
            .padding()
        } else {
            noDataView
        }
    }

    private var noDataView: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No data — open Claude Meter to start polling.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Large widget

private struct LargeWidgetView: View {
    let entry: ClaudeMeterEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Claude Meter")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                updatedLabel
            }

            if let snap = entry.snapshot {
                WindowRow(label: "SESSION",          window: snap.limits.currentSession)
                Divider().opacity(0.2)
                WindowRow(label: "WEEK (ALL MODELS)", window: snap.limits.currentWeekAllModels)

                if let model = snap.session?.activeModel {
                    Divider().opacity(0.2)
                    HStack {
                        Text("Model")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(model)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No data available")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Open Claude Meter to start polling.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var updatedLabel: some View {
        if let pollAt = entry.snapshot?.lastSuccessfulPollAt {
            let diff = Int(entry.date.timeIntervalSince(pollAt))
            let text = diff < 5  ? "Just updated"
                     : diff < 60 ? "Updated \(diff)s ago"
                     : "Updated \(diff / 60)m ago"
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Shared window row

private struct WindowRow: View {
    let label: String
    let window: LimitWindow

    private var fraction: Double {
        (window.clampedPercent ?? 0) / 100
    }

    private var color: Color {
        severityColor(for: window.percentUsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(window.displayPercent ?? "—")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }
            WidgetProgressBar(value: fraction, color: color)
                .frame(height: 5)
            Text(resetText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var resetText: String {
        guard let date = window.resetsAt else {
            return window.rawResetText.map { "Resets \($0)" } ?? "—"
        }
        let diff = date.timeIntervalSince(Date())
        if diff <= 0 { return "Resetting…" }
        let h = Int(diff / 3600)
        let m = Int(diff.truncatingRemainder(dividingBy: 3600) / 60)
        if h == 0  { return "Resets ~\(m)m" }
        if m == 0  { return "Resets ~\(h)h" }
        return "Resets ~\(h)h \(m)m"
    }
}

// MARK: - Progress bar

private struct WidgetProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
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
                    percentUsed: 25,
                    resetsAt: Date().addingTimeInterval(2700),
                    rawResetText: "2:50pm"
                ),
                currentWeekAllModels: LimitWindow(
                    percentUsed: 82,
                    resetsAt: Date().addingTimeInterval(5 * 86400),
                    rawResetText: "Jun 27 at 3pm"
                )
            ),
            state: SnapshotState(status: .ok, severity: .warning)
        )
    )
}

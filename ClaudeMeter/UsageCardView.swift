import SwiftUI
import ClaudeMeterCore

struct UsageCardView: View {
    let label: String
    let window: LimitWindow
    let now: Date
    var thresholds: UsageThresholds = .default

    /// Rolling windows past their reset read as 0% (see `LimitWindow.resolved`),
    /// so an idle session never lingers on a stale percentage.
    private var resolvedWindow: LimitWindow { window.resolved(asOf: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                percentBadge
            }
            progressBar
            resetTimeLabel
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Percent badge

    @ViewBuilder
    private var percentBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(percentText)
                .font(.body.weight(.semibold))
                .foregroundStyle(percentColor)
                .monospacedDigit()
            severityIcon
        }
    }

    private var percentText: String {
        resolvedWindow.displayPercent ?? resolvedWindow.rawValueText ?? "—"
    }

    @ViewBuilder
    private var severityIcon: some View {
        switch severity {
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .critical, .overLimit:
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(progressFillColor)
                    .frame(width: max(0, geo.size.width * fillFraction))
            }
        }
        .frame(height: 5)
    }

    // MARK: - Reset label

    @ViewBuilder
    private var resetTimeLabel: some View {
        if let resetsAt = resolvedWindow.resetsAt {
            Text(resetDescription(resetsAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let raw = resolvedWindow.rawResetText {
            Text(raw == "rolling 7 days" ? "Last 7 days" : "Resets \(raw)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var severity: UsageSeverity {
        thresholds.severity(for: resolvedWindow.percentUsed)
    }

    private var percentColor: Color {
        switch severity {
        case .normal:   return .primary
        case .warning:  return .orange
        case .critical, .overLimit: return .red
        case .unknown:  return .secondary
        }
    }

    private var progressFillColor: Color {
        switch severity {
        case .normal:   return .accentColor
        case .warning:  return .orange
        case .critical, .overLimit: return .red
        case .unknown:  return Color.primary.opacity(0.25)
        }
    }

    private var fillFraction: Double {
        guard let pct = resolvedWindow.clampedPercent else { return 0 }
        return min(1.0, pct / 100.0)
    }

    private func resetDescription(_ date: Date) -> String {
        guard date > now else { return "Resetting…" }
        let interval = date.timeIntervalSince(now)
        // Near-term windows (e.g. the 5-hour session) read better as a countdown;
        // windows days away read better as an absolute date.
        if interval >= 24 * 3600 {
            return "Resets \(Self.dateTimeFormatter.string(from: date))"
        }
        if interval < 60 { return "Resets in 1m" }
        let relative = Self.durationFormatter.string(from: interval) ?? "soon"
        return "Resets in \(relative)"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute]
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .medium
        return f
    }()

    private var accessibilityText: String {
        var parts = ["\(label) usage \(percentText)"]
        if let resetsAt = resolvedWindow.resetsAt {
            parts.append(resetDescription(resetsAt))
        }
        return parts.joined(separator: ", ")
    }
}

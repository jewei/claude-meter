import SwiftUI
import ClaudeMeterCore

struct UsageCardView: View {
    let label: String
    let window: LimitWindow
    let now: Date
    var thresholds: UsageThresholds = .default

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
        window.displayPercent ?? window.rawValueText ?? "—"
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
        if let resetsAt = window.resetsAt {
            Text(resetDescription(resetsAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let raw = window.rawResetText {
            Text(raw == "rolling 7 days" ? "Last 7 days" : "Resets \(raw)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var severity: UsageSeverity {
        thresholds.severity(for: window.percentUsed)
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
        guard let pct = window.clampedPercent else { return 0 }
        return min(1.0, pct / 100.0)
    }

    private func resetDescription(_ date: Date) -> String {
        guard date > now else { return "Resetting…" }
        let interval = date.timeIntervalSince(now)
        if interval < 3600 {
            let mins = max(1, Int(interval / 60))
            return "Resets in \(mins)m"
        }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "Resets at \(Self.timeFormatter.string(from: date))"
        }
        return "Resets \(Self.dateTimeFormatter.string(from: date))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
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
        if let resetsAt = window.resetsAt {
            parts.append(resetDescription(resetsAt))
        }
        return parts.joined(separator: ", ")
    }
}

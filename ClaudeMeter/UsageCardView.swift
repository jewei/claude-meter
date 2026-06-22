import SwiftUI
import ClaudeMeterCore

struct UsageCardView: View {
    let label: String
    let window: LimitWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                percentBadge
            }
            progressBar
            resetTimeLabel
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Percent badge

    @ViewBuilder
    private var percentBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(percentText)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(severityColor)
            severityIcon
        }
    }

    private var percentText: String {
        window.displayPercent ?? "—"
    }

    @ViewBuilder
    private var severityIcon: some View {
        switch severity {
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.cmWarning)
        case .critical, .overLimit:
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.cmCritical)
        default:
            EmptyView()
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(severityColor)
                    .frame(width: geo.size.width * fillFraction)
                    .shadow(color: severityColor.opacity(0.5), radius: 4)
            }
        }
        .frame(height: 4)
    }

    // MARK: - Reset label

    @ViewBuilder
    private var resetTimeLabel: some View {
        if let resetsAt = window.resetsAt {
            Text(resetDescription(resetsAt))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else if let raw = window.rawResetText {
            Text("Resets \(raw)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var severity: UsageSeverity {
        UsageSeverity.from(percent: window.percentUsed)
    }

    private var severityColor: Color {
        switch severity {
        case .normal:   return .cmNormal
        case .warning:  return .cmWarning
        case .critical, .overLimit: return .cmCritical
        case .unknown:  return .secondary
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

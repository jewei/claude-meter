import ClaudeMeterCore
import SwiftUI

struct UsageCardView: View {
    let label: String
    let window: LimitWindow
    let now: Date
    var thresholds: UsageThresholds = .default
    /// The window's rolling span, used to derive consumption pace. `nil` hides
    /// the pace badge (e.g. for windows whose duration we don't model).
    var paceKind: LimitWindowKind? = nil
    /// Optional brand glyph (asset name) shown before the title.
    var leadingIcon: String? = nil
    var leadingIconColor: Color = .secondary

    /// Rolling windows past their reset read as 0% (see `LimitWindow.resolved`),
    /// so an idle session never lingers on a stale percentage.
    private var resolvedWindow: LimitWindow { window.resolved(asOf: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let leadingIcon {
                    Image(leadingIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                        .foregroundStyle(leadingIconColor)
                }
                Text(label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                percentBadge
            }
            progressBar
            HStack(spacing: 6) {
                resetTimeLabel
                Spacer(minLength: 0)
                paceBadge
            }
            forecastLine
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
                .foregroundStyle(.warningTint)
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
            Text("Resets \(raw)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pace badge

    /// The resolved window's consumption pace, when a window span is known and a
    /// reset time exists. Driven by `resolvedWindow` so a just-reset window reads
    /// `.unknown` and the badge hides.
    private var pace: UsagePace {
        guard let paceKind else { return .unknown }
        return resolvedWindow.pace(kind: paceKind, asOf: now)
    }

    @ViewBuilder
    private var paceBadge: some View {
        // Hidden when the forecast line is showing — the concrete run-out forecast
        // supersedes the relative pace badge, so the card never stacks two amber
        // "burning hot" signals saying the same thing.
        if paceKind != nil, pace != .unknown, runsOutLine == nil {
            HStack(spacing: 3) {
                Image(systemName: pace.symbolName)
                Text(pace.displayName)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(paceColor)
            .help(paceInsightText)
        }
    }

    private var paceInsightText: String {
        guard let paceKind else { return "" }
        return resolvedWindow.paceInsight(kind: paceKind, asOf: now)
            ?? "Usage relative to time elapsed in this window"
    }

    // MARK: - Forecast line

    /// A glanceable run-out warning, shown only when the window is genuinely burning
    /// *ahead* of pace AND projected to empty before it resets — the actionable case
    /// the reset countdown and pace badge don't quantify. When shown it replaces the
    /// pace badge (see `paceBadge`), so it never contradicts an "On track" badge.
    @ViewBuilder
    private var forecastLine: some View {
        if let runsOutLine {
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                Text(runsOutLine)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.warningTint)
        }
    }

    private var runsOutLine: String? {
        guard let paceKind, pace == .ahead,
            case .runsOut(let seconds) = resolvedWindow.runsOutEstimate(kind: paceKind, asOf: now)
        else { return nil }
        if seconds < 60 { return "Empty in under a minute" }
        return "Empty in ~\(formattedRunsOut(seconds, kind: paceKind)) at this rate"
    }

    private func formattedRunsOut(_ seconds: TimeInterval, kind: LimitWindowKind) -> String {
        RunsOutText.formatted(seconds, kind: kind)
    }

    private var paceColor: Color {
        switch pace {
        case .ahead: return .warningTint
        case .behind: return .green
        case .onPace: return .secondary
        case .unknown: return .secondary
        }
    }

    // MARK: - Helpers

    private var severity: UsageSeverity {
        thresholds.severity(for: resolvedWindow.percentUsed)
    }

    private var percentColor: Color {
        switch severity {
        case .normal: return .primary
        case .warning: return .warningTint
        case .critical, .overLimit: return .red
        case .unknown: return .secondary
        }
    }

    private var progressFillColor: Color {
        switch severity {
        case .normal: return .accentColor
        case .warning: return .warningTint
        case .critical, .overLimit: return .red
        case .unknown: return Color.primary.opacity(0.25)
        }
    }

    private var fillFraction: Double {
        guard let pct = resolvedWindow.clampedPercent else { return 0 }
        return min(1.0, pct / 100.0)
    }

    private func resetDescription(_ date: Date) -> String {
        guard let phrase = ResetPhrase.spoken(until: date, asOf: now) else { return "Resetting…" }
        return "Resets \(phrase)"
    }

    private var accessibilityText: String {
        var parts = ["\(label) usage \(percentText)"]
        if let resetsAt = resolvedWindow.resetsAt {
            parts.append(resetDescription(resetsAt))
        }
        if let runsOutLine {
            parts.append(runsOutLine)
        } else if paceKind != nil, pace != .unknown {
            parts.append(pace.displayName)
        }
        return parts.joined(separator: ", ")
    }
}

/// Run-out duration formatting shared by the popover card and notifications, so the
/// same forecast never renders with different precision on the two surfaces. Units
/// suit the window: a weekly window can be days out (day/hour), a session is
/// hours/minutes — so a 2-day projection reads "2d 4h", not "52h".
enum RunsOutText {
    static func formatted(_ seconds: TimeInterval, kind: LimitWindowKind) -> String {
        let formatter = kind == .weekly ? dayHourFormatter : durationFormatter
        let text = formatter.string(from: seconds) ?? ""
        return text.isEmpty ? "under a minute" : text
    }

    static let dayHourFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.day, .hour]
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        return f
    }()

    static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute]
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        return f
    }()
}

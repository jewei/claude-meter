import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI

/// The Usage and Spend window: a daily cost chart and per-model rows over a
/// chosen range.
///
/// Deliberately not a popover section. The popover is 360 points wide, which is
/// too narrow for 30 daily bars, and this view runs its own scan with its own
/// lifecycle instead of borrowing the poll's seven-day cost reading.
///
/// Every amount is an estimate from local transcripts, priced from the model
/// catalogue. It is not a bill, and the view says so rather than implying that a
/// total is authoritative.
struct UsageSpendView: View {
    @EnvironmentObject var appState: AppState
    @State private var range = 7
    @State private var copiedExport = false

    /// The window offers these two ranges only. A longer window reaches the
    /// scanner's per-root record cap often enough that the chart would mostly
    /// show truncated bars.
    private static let ranges = [7, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if appState.spendBreakdownLoading, appState.spendBreakdown == nil {
                placeholder("Reading transcripts…")
            } else if let error = appState.spendBreakdownError, appState.spendBreakdown == nil {
                placeholder(error)
            } else if let result = appState.spendBreakdown, !result.isEmpty {
                if result.isPartialEstimate { partialNotice }
                DailyCostChart(rows: result.daily, isPartial: result.isPartialEstimate)
                modelRows(result)
            } else {
                placeholder("No local usage in this range.")
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 520)
        .background(Color.pfPopover)
        .background(UsageSpendWindowAccessor())
        .onAppear { appState.loadSpendBreakdown(daysBack: range) }
        .onDisappear { appState.cancelSpendBreakdownLoad() }
        .onChange(of: range) { _, newValue in
            appState.loadSpendBreakdown(daysBack: newValue)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage & Spend").font(PFont.display(22, .semibold))
                    .foregroundStyle(Color.pfInk)
                Text(totalText).font(PFont.body(13, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            Spacer(minLength: 8)
            Picker("Range", selection: $range) {
                ForEach(Self.ranges, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            if appState.spendBreakdownLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var totalText: String {
        guard let result = appState.spendBreakdown, !result.isEmpty else {
            return "Estimated from local transcripts"
        }
        let total = result.models.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
        let qualifier = result.isPartialEstimate ? "at least " : "about "
        return "\(qualifier)\(SpendBreakdownFormat.money(total)) estimated over \(range) days"
    }

    /// The scanner truncates by sorted path, not by date, so a capped scan can
    /// short any day. Say that plainly instead of drawing bars that look whole.
    private var partialNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.pfEnergyLow)
            Text(
                "This range is incomplete, so any day can be understated. "
                    + "Treat the bars as a floor, not a total."
            )
            .font(PFont.body(12, .semibold))
            .foregroundStyle(Color.pfInk)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.pfEnergyLow.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func modelRows(_ result: CostUsageResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BY MODEL").font(PFont.body(11, .bold))
                .foregroundStyle(Color.pfInkMuted).tracking(0.8)
            ForEach(result.models, id: \.name) { model in
                HStack(spacing: 12) {
                    Text(model.displayName)
                        .font(PFont.body(13, .semibold)).foregroundStyle(Color.pfInk)
                    Spacer(minLength: 8)
                    Text(Self.tokens(model))
                        .font(PFont.body(12, .semibold)).foregroundStyle(Color.pfInkMuted)
                    Text(SpendBreakdownFormat.money(model.costUsd ?? 0))
                        .font(PFont.body(13, .bold)).foregroundStyle(Color.pfInk)
                        .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 6)
                Divider().overlay(Color.pfCardBorder)
            }
        }
        .padding(16)
        .chunkyCard(radius: 18)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                copyExport()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: copiedExport ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .bold))
                    Text(copiedExport ? "Copied" : "Copy JSON")
                        .font(PFont.display(13, .semibold))
                }
                .foregroundStyle(Color.pfInk).padding(.horizontal, 14).padding(.vertical, 9)
                .chunkyCard(radius: 12)
            }
            .buttonStyle(.plain)
            .disabled(appState.spendBreakdown?.isEmpty ?? true)
            Text("Estimates from local transcripts. Not a bill.")
                .font(PFont.body(12, .semibold)).foregroundStyle(Color.pfInkMuted)
            Spacer(minLength: 0)
        }
    }

    private func placeholder(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text).font(PFont.body(13, .semibold)).foregroundStyle(Color.pfInkMuted)
            Spacer()
        }
        .frame(minHeight: 220)
    }

    // MARK: - Export

    private func copyExport() {
        guard let result = appState.spendBreakdown,
            let text = SpendBreakdownFormat.exportJSON(result, rangeDays: range)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedExport = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedExport = false
        }
    }

    private static func tokens(_ model: ModelUsage) -> String {
        let total =
            (model.inputTokens ?? 0) + (model.outputTokens ?? 0)
            + (model.cacheReadTokens ?? 0) + (model.cacheWriteTokens ?? 0)
        return "\(SpendBreakdownFormat.compact(total)) tokens"
    }
}

/// The window's pure presentation rules: day aggregation, formatting, and the
/// export payload. Kept out of the view so each can be tested without AppKit.
enum SpendBreakdownFormat {
    static func money(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value > 0, value < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }

    /// Promotes at the point where the lower unit would round to 1000, so 999,500
    /// reads as `1.0M` rather than `1000K`. Uses the unsigned magnitude, so
    /// `Int.min` cannot overflow on negation.
    static func compact(_ value: Int) -> String {
        let magnitude = value.magnitude
        if magnitude >= 999_500_000 { return String(format: "%.1fB", Double(value) / 1e9) }
        if magnitude >= 999_500 { return String(format: "%.1fM", Double(value) / 1e6) }
        if magnitude >= 1000 { return String(format: "%.1fK", Double(value) / 1e3) }
        return "\(value)"
    }

    /// One bar per day, summed across models, in ascending day order.
    ///
    /// A day with no rows is absent rather than zero: the scan can be truncated,
    /// so the view must not draw a confident zero for a day it never read.
    static func dailyTotals(_ rows: [DailyModelUsage]) -> [(day: String, cost: Double)] {
        var totals: [String: Double] = [:]
        for row in rows {
            let cost = row.costUsd ?? 0
            guard cost.isFinite else { continue }
            totals[row.day, default: 0] += cost
        }
        return totals.keys.sorted().map { ($0, totals[$0] ?? 0) }
    }

    /// The clipboard export.
    ///
    /// Carries the rows only. Project and session paths are deliberately absent,
    /// because a user pasting this into an issue must not publish their directory
    /// layout. `isPartialEstimate` travels with the data so a reader cannot
    /// mistake a truncated range for a complete one.
    static func exportJSON(
        _ result: CostUsageResult,
        rangeDays: Int,
        generatedAt: Date = Date()
    ) -> String? {
        let payload: [String: Any] = [
            "rangeDays": rangeDays,
            "isPartialEstimate": result.isPartialEstimate,
            "generatedAt": ISO8601DateFormatter().string(from: generatedAt),
            "daily": result.daily.map { row in
                [
                    "day": row.day, "model": row.model,
                    "inputTokens": row.inputTokens ?? 0,
                    "outputTokens": row.outputTokens ?? 0,
                    "cacheReadTokens": row.cacheReadTokens ?? 0,
                    "cacheWriteTokens": row.cacheWriteTokens ?? 0,
                    "estimatedCostUsd": row.costUsd ?? 0,
                ]
            },
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Hand-drawn daily bars, matching the app's own activity grid rather than
/// introducing a charting framework with a different visual language.
struct DailyCostChart: View {
    let rows: [DailyModelUsage]
    let isPartial: Bool

    /// One bar per day, summed across models, in the scanner's day order.
    private var days: [(day: String, cost: Double)] {
        SpendBreakdownFormat.dailyTotals(rows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BY DAY").font(PFont.body(11, .bold))
                .foregroundStyle(Color.pfInkMuted).tracking(0.8)
            GeometryReader { geometry in
                let peak = max(days.map(\.cost).max() ?? 0, 0.01)
                let spacing: CGFloat = days.count > 14 ? 3 : 6
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(days, id: \.day) { entry in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isPartial ? Color.pfInkMuted : Color.pfEnergyFull)
                                .frame(
                                    height: max(
                                        2, geometry.size.height * 0.82 * (entry.cost / peak)))
                        }
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .help("\(entry.day) · \(SpendBreakdownFormat.money(entry.cost))")
                        .accessibilityLabel(
                            "\(entry.day), \(SpendBreakdownFormat.money(entry.cost))")
                    }
                }
                .frame(height: geometry.size.height, alignment: .bottom)
            }
            .frame(height: 160)
        }
        .padding(16)
        .chunkyCard(radius: 18)
    }
}

/// Titles the window and keeps it inside the activation-policy rule, so an
/// `LSUIElement` app is never dropped to `.accessory` while it is on screen.
private struct UsageSpendWindowAccessor: NSViewRepresentable {
    static let windowTitle = "Claude Meter — Usage & Spend"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.title = Self.windowTitle }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.title = Self.windowTitle }
    }
}

/// Whether the Usage and Spend window is currently on screen.
@MainActor
func isUsageSpendWindowVisible() -> Bool {
    NSApp.windows.contains {
        $0.isVisible && $0.title == UsageSpendWindowAccessor.windowTitle
    }
}

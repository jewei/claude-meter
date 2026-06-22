import SwiftUI
import Charts
import ClaudeMeterCore

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var records: [HistoryRecord] = []
    @State private var timeRange: TimeRange = .day
    @State private var feedbackMessage: String?

    enum TimeRange: String, CaseIterable, Identifiable {
        case hour = "1H"
        case sixH = "6H"
        case day  = "24H"
        case week = "7D"
        var id: String { rawValue }
        var interval: TimeInterval {
            switch self {
            case .hour: return 3_600
            case .sixH: return 6 * 3_600
            case .day:  return 24 * 3_600
            case .week: return 7 * 24 * 3_600
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            Picker("Range", selection: $timeRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if records.isEmpty {
                emptyState
            } else {
                trendChart
            }

            Divider()
            exportRow
        }
        .frame(width: 520, height: 400)
        .background(Color.cmBackground)
        .onAppear { loadRecords() }
        .onChange(of: timeRange) { _, _ in loadRecords() }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Usage History")
                .font(.title3.bold())
                .foregroundStyle(.primary)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Chart

    private var trendChart: some View {
        Chart(chartPoints, id: \.id) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Usage %", point.percent)
            )
            .foregroundStyle(by: .value("Metric", point.series))
            .interpolationMethod(.catmullRom)
        }
        .chartForegroundStyleScale([
            "Session": Color.cmNormal,
            "Week":    Color.cmWarning,
        ])
        .chartYScale(domain: 0...110)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xLabel(date)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .trailing)
        .padding()
        .frame(maxHeight: .infinity)
    }

    private func xLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = timeRange == .week ? "EEE d" : "HH:mm"
        return fmt.string(from: date)
    }

    private var chartPoints: [ChartPoint] {
        records.flatMap { record -> [ChartPoint] in
            var pts: [ChartPoint] = []
            if let s = record.sessionPercent {
                pts.append(ChartPoint(date: record.createdAt, percent: s, series: "Session"))
            }
            if let w = record.weekPercent {
                pts.append(ChartPoint(date: record.createdAt, percent: w, series: "Week"))
            }
            return pts
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No history for this period")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Data accumulates as Claude Meter polls in the background.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Export row

    private var exportRow: some View {
        HStack(spacing: 12) {
            Button("Copy CSV") { copyExport(csv: true) }
                .buttonStyle(.borderless)
            Button("Copy JSON") { copyExport(csv: false) }
                .buttonStyle(.borderless)
            if let msg = feedbackMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(Color.cmNormal)
                    .transition(.opacity)
            }
            Spacer()
            Text(records.isEmpty ? "No records" : "\(records.count) records")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .animation(.easeOut(duration: 0.2), value: feedbackMessage)
    }

    // MARK: - Data loading

    private func loadRecords() {
        let store = appState.historyStore
        let since = Date().addingTimeInterval(-timeRange.interval)
        Task {
            records = (try? await store?.fetchAsync(since: since)) ?? []
        }
    }

    private func copyExport(csv: Bool) {
        let store = appState.historyStore
        let since = Date().addingTimeInterval(-timeRange.interval)
        Task {
            let text: String?
            if csv {
                text = try? store?.exportCSV(since: since)
            } else {
                text = try? store?.exportJSON(since: since)
            }
            guard let text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            feedbackMessage = "Copied!"
            try? await Task.sleep(for: .seconds(2))
            feedbackMessage = nil
        }
    }
}

// MARK: - Chart data point

private struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let percent: Double
    let series: String
}

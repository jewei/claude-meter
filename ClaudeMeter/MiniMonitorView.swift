import SwiftUI
import AppKit
import ClaudeMeterCore

struct MiniMonitorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            metricColumn(
                label: "SESSION",
                value: appState.snapshot?.limits.currentSession.displayPercent,
                percent: appState.snapshot?.limits.currentSession.percentUsed
            )
            Divider()
                .frame(height: 28)
            metricColumn(
                label: "WEEK",
                value: appState.snapshot?.limits.currentWeekAllModels.displayPercent,
                percent: appState.snapshot?.limits.currentWeekAllModels.percentUsed
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 240, height: 64)
        .background(Color.cmBackground)
        .background(WindowFloatingHook())
    }

    private func metricColumn(label: String, value: String?, percent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(severityColor(for: percent))
                .monospacedDigit()
        }
    }

    private func severityColor(for percent: Double?) -> Color {
        let thresholds = AppState.currentThresholds()
        switch thresholds.severity(for: percent) {
        case .normal:              return .cmNormal
        case .warning:             return .cmWarning
        case .critical, .overLimit: return .cmCritical
        case .unknown:             return Color.secondary
        }
    }
}

// MARK: - Window level hook

/// Sets the host window to always-on-top floating level and enables drag-by-background.
private struct WindowFloatingHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

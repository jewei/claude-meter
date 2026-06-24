import SwiftUI
import ClaudeMeterCore

struct MenuBarLabel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .rotationEffect(appState.isLoading ? .degrees(360) : .zero)
                .animation(
                    appState.isLoading
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: appState.isLoading
                )
            if let text = labelText {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(appState.isActive ? .primary : .secondary)
        .opacity(appState.isActive ? 1 : 0.5)
    }

    private var iconName: String {
        if appState.isLoading { return "arrow.clockwise" }
        if showsErrorIcon { return "exclamationmark.circle" }
        if appState.isStale { return "clock.badge.exclamationmark" }
        switch appState.severity {
        case .warning: return "gauge.with.dots.needle.67percent"
        case .critical, .overLimit: return "gauge.with.dots.needle.100percent"
        default: return "gauge.with.dots.needle.33percent"
        }
    }

    private var showsErrorIcon: Bool {
        if appState.lastError != nil && appState.snapshot == nil { return true }
        if AppSettings.cursorSourceEnabled,
           appState.cursorError != nil,
           appState.cursorUsage == nil,
           appState.snapshot == nil {
            return true
        }
        return false
    }

    private var labelText: String? {
        // Paused: show only the dimmed icon, no usage percent.
        guard appState.isActive else { return nil }
        let now = Date()
        if let snap = appState.snapshot {
            return snap.limits.bindingDisplayPercent(asOf: now)
        }
        if AppSettings.cursorSourceEnabled,
           let percent = appState.cursorUsage?.clampedPercent {
            return "\(Int(percent.rounded()))%"
        }
        return nil
    }
}

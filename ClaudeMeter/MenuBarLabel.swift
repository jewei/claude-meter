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
    }

    private var iconName: String {
        if appState.isLoading { return "arrow.clockwise" }
        if appState.lastError != nil && appState.snapshot == nil {
            return "exclamationmark.circle"
        }
        if appState.isStale { return "clock.badge.exclamationmark" }
        switch appState.severity {
        case .warning: return "gauge.with.dots.needle.67percent"
        case .critical, .overLimit: return "gauge.with.dots.needle.100percent"
        default: return "gauge.with.dots.needle.33percent"
        }
    }

    private var labelText: String? {
        guard let snap = appState.snapshot else { return nil }
        return snap.limits.currentSession.displayPercent
    }
}

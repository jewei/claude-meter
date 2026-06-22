import SwiftUI
import ClaudeMeterCore

struct MenuBarLabel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .rotationEffect(appState.isLoading ? .degrees(360) : .zero)
                .animation(
                    appState.isLoading
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: appState.isLoading
                )
            if let text = labelText {
                Text(text)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(iconColor)
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

    private var iconColor: Color {
        switch appState.severity {
        case .warning: return .cmWarning
        case .critical, .overLimit: return .cmCritical
        case .unknown where appState.lastError != nil: return .cmCritical
        default: return .primary
        }
    }

    private var labelText: String? {
        guard let snap = appState.snapshot else { return nil }
        let s = snap.limits.currentSession
        let w = snap.limits.currentWeekAllModels

        switch (s.displayPercent, w.displayPercent) {
        case let (sp?, wp?): return "\(sp)/\(wp)"
        case let (sp?, nil): return sp
        case let (nil, wp?): return wp
        default: return nil
        }
    }
}

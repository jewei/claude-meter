import ClaudeMeterCore
import SwiftUI

enum MenuBarText {
    private struct Candidate {
        let window: LimitWindow
        let kind: LimitWindowKind
        let left: Double
    }

    static func forecast(
        consideredLimits: [LimitInfo],
        progression: AppGroupConfig.ProgressionMode,
        now: Date
    ) -> String? {
        let candidates: [Candidate] = consideredLimits.flatMap(\.bindingWindows).compactMap {
            descriptor in
            let window = descriptor.window.resolved(asOf: now)
            guard let left = window.percentLeft(asOf: now) else { return nil }
            return Candidate(window: window, kind: descriptor.scope.kind, left: left)
        }
        guard let nearest = candidates.min(by: { $0.left < $1.left }) else { return nil }
        let percent = progression == .used ? 100 - nearest.left : nearest.left
        let percentText = "\(Int(percent.rounded()))%"
        let estimate = nearest.window.runsOutEstimate(kind: nearest.kind, asOf: now)
        guard let forecast = RunsOutPhrase.compact(estimate) else { return percentText }
        return "\(percentText) · \(forecast)"
    }
}

/// Menu-bar item for the explicitly selected main meter. Provider selection is
/// stable until the user changes it; missing data never falls back to another source.
struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppGroupConfig.progressionModeKey) private var progressionMode = "left"
    @AppStorage(AppGroupConfig.mainMeterProviderKey) private var mainMeterProvider = "claude"
    @AppStorage(AppGroupConfig.menuBarAccountKey) private var claudeAccountPin = ""
    @AppStorage(AppGroupConfig.codexMainMeterAccountKey) private var codexAccountPin = ""
    @AppStorage(AppGroupConfig.menuBarWindowKey) private var menuBarWindow = "nearest"

    private var progression: AppGroupConfig.ProgressionMode {
        AppGroupConfig.ProgressionMode(rawValue: progressionMode) ?? .left
    }

    private var selectedWindow: AppGroupConfig.MenuBarWindow {
        AppGroupConfig.MenuBarWindow(rawValue: menuBarWindow) ?? .nearest
    }

    var body: some View {
        HStack(spacing: 4) {
            iconView
            if let text = leftText {
                Text(text)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(appState.isActive ? .primary : .secondary)
        .opacity(appState.isActive ? 1 : 0.55)
    }

    // MARK: - Icon

    @ViewBuilder
    private var iconView: some View {
        if appState.mainMeterIsLoading {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .bold))
                .rotationEffect(.degrees(360))
                .animation(
                    reduceMotion
                        ? nil : .linear(duration: 1).repeatForever(autoreverses: false),
                    value: appState.mainMeterIsLoading)
        } else if showsErrorIcon {
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
        } else {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                statusBadge
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !appState.isActive {
            EmptyView()
        } else if appState.mainMeterIsStale {
            dot(Color.secondary)
        } else if appState.mainMeterSeverity == .overLimit {
            tappedOutBadge
        } else {
            switch appState.mainMeterSeverity {
            case .critical:
                if reduceMotion { dot(.pfEnergyEmpty) } else { pulsingDot(.pfEnergyEmpty) }
            case .warning:
                dot(.pfEnergyLow)
            case .normal:
                dot(.pfEnergyFull)
            default:
                dot(Color.secondary)  // .unknown (.overLimit is handled above)
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .offset(x: 3, y: -3)
    }

    private func pulsingDot(_ color: Color) -> some View {
        // Capped at 12 fps — an uncapped .animation schedule runs the status
        // item's display link at full refresh rate for a 1.2 s pulse.
        TimelineView(.animation(minimumInterval: 1 / 12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 2 * .pi / 1.2) + 1) / 2  // 0…1 over 1.2s
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .scaleEffect(1 + 0.35 * phase)
                .opacity(1 - 0.45 * phase)
                .offset(x: 3, y: -3)
        }
    }

    private var tappedOutBadge: some View {
        Text("0")
            .font(.system(size: 7, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 2)
            .frame(minWidth: 10, minHeight: 10)
            .background(Capsule().fill(Color.pfEnergyEmpty))
            .offset(x: 5, y: -4)
    }

    private var showsErrorIcon: Bool {
        appState.mainMeterReading == nil && appState.mainMeterError != nil
    }

    // MARK: - Main-meter number

    private var leftText: String? {
        // Hide stale numbers so cached quota cannot be mistaken for a fresh reading.
        guard appState.isActive, !appState.mainMeterIsStale else { return nil }
        _ = mainMeterProvider
        _ = claudeAccountPin
        _ = codexAccountPin
        let now = Date()
        switch selectedWindow {
        case .fiveHour:
            return part(
                appState.mainMeterReading?.limits.currentSession,
                suffix: "5h",
                now: now)
        case .sevenDay:
            return part(
                appState.mainMeterReading?.limits.currentWeekAllModels,
                suffix: "7d",
                now: now)
        case .both:
            let limits = appState.mainMeterReading?.limits
            let parts = [
                part(limits?.currentSession, suffix: "5h", now: now),
                part(limits?.currentWeekAllModels, suffix: "7d", now: now),
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .nearest:
            return nearestText(now: now)
        case .forecast:
            return MenuBarText.forecast(
                consideredLimits: appState.mainMeterLimitSets,
                progression: progression,
                now: now)
        }
    }

    /// "99% 5h" for one window (energy-left, or usage when in "used" mode), or nil
    /// when the window has no value.
    /// Energy-left, or usage when in "used" mode.
    private func displayed(_ left: Double) -> Double {
        progression == .used ? 100 - left : left
    }

    private func part(_ window: LimitWindow?, suffix: String, now: Date) -> String? {
        guard let left = window?.percentLeft(asOf: now) else { return nil }
        return "\(Int(displayed(left).rounded()))% \(suffix)"
    }

    /// Lowest energy-left across every window of every menu-bar account — the
    /// nearest limit. No window suffix (it may come from any window/account).
    private func nearestText(now: Date) -> String? {
        let lefts = appState.mainMeterLimitSets.flatMap { limits in
            limits.bindingWindows.compactMap { $0.window.percentLeft(asOf: now) }
        }
        guard let minLeft = lefts.min() else { return nil }
        // "Used" mode shows the max usage (= the nearest limit, inverted).
        return "\(Int(displayed(minLeft).rounded()))%"
    }
}

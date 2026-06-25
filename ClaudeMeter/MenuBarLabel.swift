import ClaudeMeterCore
import SwiftUI

/// Menu-bar item: an energy bolt + a status dot that mirrors the *nearest-limit*
/// account (green = safe, orange = getting low, red = almost dry, pulsing when
/// critical, a "0" badge when tapped out). A compact energy-left % rides along so
/// the exact headroom stays glanceable.
struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        if appState.isLoading {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .bold))
                .rotationEffect(.degrees(360))
                .animation(
                    .linear(duration: 1).repeatForever(autoreverses: false),
                    value: appState.isLoading)
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
        } else if appState.isStale {
            dot(Color.secondary)
        } else if appState.severity == .overLimit {
            tappedOutBadge
        } else {
            switch appState.severity {
            case .critical:
                if reduceMotion { dot(.pfEnergyEmpty) } else { pulsingDot(.pfEnergyEmpty) }
            case .warning:
                dot(.pfEnergyLow)
            case .normal:
                dot(.pfEnergyFull)
            case .unknown, .overLimit:
                dot(Color.secondary)
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
        TimelineView(.animation) { context in
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
        if appState.lastError != nil && appState.snapshot == nil { return true }
        if AppSettings.cursorSourceEnabled,
            appState.cursorError != nil,
            appState.cursorUsage == nil,
            appState.snapshot == nil
        {
            return true
        }
        return false
    }

    // MARK: - Energy-left number (nearest limit)

    private var leftText: String? {
        guard appState.isActive else { return nil }
        let now = Date()
        var lefts: [Double] = []
        if let snap = appState.snapshot {
            let limitSets: [LimitInfo] =
                (snap.accounts?.isEmpty == false) ? snap.accounts!.map(\.limits) : [snap.limits]
            for limits in limitSets {
                let windows = [
                    limits.currentSession, limits.currentWeekAllModels, limits.currentWeekOpus,
                ].compactMap { $0 }
                lefts.append(contentsOf: windows.compactMap { $0.percentLeft(asOf: now) })
            }
        }
        if AppSettings.cursorSourceEnabled, let cursor = appState.cursorUsage?.clampedPercent {
            lefts.append(100 - cursor)
        }
        guard let minLeft = lefts.min() else { return nil }
        return "\(Int(minLeft.rounded()))%"
    }
}

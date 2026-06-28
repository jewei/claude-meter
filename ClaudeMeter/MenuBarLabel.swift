import ClaudeMeterCore
import SwiftUI

/// Menu-bar item: an energy bolt + a status dot that mirrors the *nearest-limit*
/// account (green = safe, orange = getting low, red = almost dry, pulsing when
/// critical, a "0" badge when tapped out). A compact energy-left % rides along so
/// the exact headroom stays glanceable.
struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppGroupConfig.progressionModeKey) private var progressionMode = "left"
    @AppStorage(AppGroupConfig.menuBarAccountKey) private var menuBarAccountPin = ""
    @AppStorage(AppGroupConfig.menuBarWindowKey) private var menuBarWindow = "nearest"

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
                    reduceMotion ? .default : .linear(duration: 1).repeatForever(autoreverses: false),
                    value: appState.isLoading)
        } else if showsErrorIcon {
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
        } else {
            ZStack(alignment: .topTrailing) {
                boltIcon
                // The attention glyph carries its own badge, so hide the severity dot
                // then to avoid a corner collision (the "% 5h" text still shows quota).
                if !attentionNeeded {
                    statusBadge
                }
            }
        }
    }

    private var attentionNeeded: Bool {
        appState.isActive && appState.attention.needsAttention
    }

    /// The bolt. Turns amber (and gently pulses) when a Claude Code session needs
    /// attention — a channel distinct from the quota dot, so the two never collide.
    @ViewBuilder
    private var boltIcon: some View {
        // The menu bar template-tints SF Symbols (custom color ignored) and doesn't
        // run symbol animations, so attention is signalled by a glyph change — a
        // bell-with-badge reads unmistakably as "needs you". Color + motion + detail
        // live where they render: the popover banner and the notification.
        Image(systemName: attentionNeeded ? "bell.badge.fill" : "bolt.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(appState.isActive ? .primary : .secondary)
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
        // Claude only — a Cursor error surfaces in the popover, not the menu bar.
        appState.lastError != nil && appState.snapshot == nil
    }

    // MARK: - Energy-left number (nearest limit)

    private var leftText: String? {
        // Hide the number when stale so a stale energy % isn't mistaken for fresh
        // (the gray status dot still shows). Paused hides it too.
        guard appState.isActive, !appState.isStale else { return nil }
        _ = menuBarAccountPin  // re-render the label when the pinned account changes
        let now = Date()
        // Cursor is intentionally excluded — the menu bar reflects Claude only, and
        // honors "Menu bar follows" (pinned account vs. nearest Claude limit). Cursor
        // has its own popover card.
        switch menuBarWindow {
        case "5h":
            return part(appState.menuBarActiveLimits?.currentSession, suffix: "5h", now: now)
        case "7d":
            return part(appState.menuBarActiveLimits?.currentWeekAllModels, suffix: "7d", now: now)
        case "both":
            let limits = appState.menuBarActiveLimits
            let parts = [
                part(limits?.currentSession, suffix: "5h", now: now),
                part(limits?.currentWeekAllModels, suffix: "7d", now: now),
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        default:
            return nearestText(now: now)
        }
    }

    /// "99% 5h" for one window (energy-left, or usage when in "used" mode), or nil
    /// when the window has no value.
    private func part(_ window: LimitWindow?, suffix: String, now: Date) -> String? {
        guard let left = window?.percentLeft(asOf: now) else { return nil }
        let value = progressionMode == "used" ? 100 - left : left
        return "\(Int(value.rounded()))% \(suffix)"
    }

    /// Lowest energy-left across every window of every menu-bar account — the
    /// nearest limit. No window suffix (it may come from any window/account).
    private func nearestText(now: Date) -> String? {
        var lefts: [Double] = []
        for limits in appState.menuBarLimitSets {
            let windows = [
                limits.currentSession, limits.currentWeekAllModels, limits.currentWeekOpus,
            ].compactMap { $0 }
            lefts.append(contentsOf: windows.compactMap { $0.percentLeft(asOf: now) })
        }
        guard let minLeft = lefts.min() else { return nil }
        // "Used" mode shows the max usage (= the nearest limit, inverted).
        let value = progressionMode == "used" ? 100 - minLeft : minLeft
        return "\(Int(value.rounded()))%"
    }
}

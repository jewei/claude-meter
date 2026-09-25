import AppKit
import ClaudeMeterCore
import SwiftUI

enum MenuBarText {
    /// Spoken state is separate from the compact visual title and its color dot.
    static func accessibilitySummary(
        provider: MainMeterProvider,
        reading: MainMeterReading?,
        progression: MeterSettings.ProgressionMode,
        selection: MeterSettings.MenuBarWindow,
        isActive: Bool,
        isStale: Bool,
        isLoading: Bool,
        severity: UsageSeverity,
        now: Date
    ) -> String {
        let title = "Claude Meter. \(provider.displayName)."
        guard isActive else { return "\(title) Paused." }
        if isStale {
            return "\(title) Data is stale." + (isLoading ? " Refreshing." : "")
        }
        guard let reading, reading.provider == provider else {
            return "\(title) " + (isLoading ? "Loading." : "Usage unavailable.")
        }

        func name(_ scope: LimitWindowScope) -> String {
            switch scope {
            case .session: reading.sessionLabel == "5-hr" ? "Session" : reading.sessionLabel
            case .weekly: reading.weeklyLabel == "week" ? "Weekly" : reading.weeklyLabel
            case .weeklyOpus: "Opus weekly"
            }
        }
        func describe(_ descriptor: LimitWindowDescriptor) -> String {
            let window = descriptor.window.resolved(asOf: now)
            let label = name(descriptor.scope)
            guard let left = window.percentLeft(asOf: now) else { return "\(label) unavailable." }
            let percent = Int((progression == .used ? 100 - left : left).rounded())
            let text = "\(label) \(percent) percent \(progression == .used ? "used" : "left")."
            return text
        }

        let details: String
        switch selection {
        case .fiveHour:
            details = describe(.init(scope: .session, window: reading.limits.currentSession))
        case .sevenDay:
            details = describe(.init(scope: .weekly, window: reading.limits.currentWeekAllModels))
        case .both:
            details = [
                describe(.init(scope: .session, window: reading.limits.currentSession)),
                describe(.init(scope: .weekly, window: reading.limits.currentWeekAllModels)),
            ].joined(separator: " ")
        case .nearest:
            let nearest = reading.limits.bindingWindows.filter {
                $0.window.percentLeft(asOf: now) != nil
            }.max {
                ($0.window.resolved(asOf: now).percentUsed ?? -1)
                    < ($1.window.resolved(asOf: now).percentUsed ?? -1)
            }
            details =
                nearest.map(describe)
                ?? "Usage unavailable."
        }
        let status: String
        switch severity {
        case .normal: status = "Overall quota is normal."
        case .warning: status = "Overall quota warning."
        case .critical: status = "Overall quota is critical."
        case .overLimit: status = "Quota limit reached."
        case .unknown: status = "Overall quota status is unknown."
        }
        return "\(title) \(details) \(status)" + (isLoading ? " Refreshing." : "")
    }

}

@MainActor
enum MenuBarAccessibility {
    /// MenuBarExtra renders its label into a native button. SwiftUI's accessibility
    /// modifiers do not reach the menu-extra proxy on all supported macOS versions.
    static func update(_ summary: String, in windows: [NSWindow]) -> Bool {
        func update(_ view: NSView) -> Bool {
            if let button = view as? NSStatusBarButton {
                button.setAccessibilityTitle(summary)
                if button.accessibilityTitle() != summary {
                    // The modern setter can leave AXTitle tied to the visual text.
                    // This public instance override also reaches AppKit's AX proxy.
                    _ = button.accessibilitySetOverrideValue(summary, forAttribute: .title)
                }
                return true
            }
            return view.subviews.reduce(false) { update($1) || $0 }
        }
        return windows.reduce(false) { windowFound, window in
            guard let content = window.contentView else { return windowFound }
            return update(content) || windowFound
        }
    }

    static func publish(_ summary: String) async {
        // The label can appear just before AppKit attaches the status button.
        // Each new summary cancels its previous SwiftUI task; startup retries are bounded.
        for _ in 0..<5 {
            await Task.yield()
            guard !Task.isCancelled else { return }
            if update(summary, in: NSApp.windows) { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }
}

/// Menu-bar item for the explicitly selected main meter. Provider selection is
/// stable until the user changes it; missing data never falls back to another source.
struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MeterSettings.progressionModeKey) private var progressionMode = "left"
    @AppStorage(MeterSettings.mainMeterProviderKey) private var mainMeterProvider = "claude"
    @AppStorage(MeterSettings.menuBarAccountKey) private var claudeAccountPin = ""
    @AppStorage(MeterSettings.codexMainMeterAccountKey) private var codexAccountPin = ""
    @AppStorage(MeterSettings.menuBarWindowKey) private var menuBarWindow = "nearest"
    /// Set when the main meter becomes critical. The label lives for the whole app
    /// session, so a loading spinner or a stale period does not start a new pulse.
    @State private var criticalPulseStart: Date?

    static let criticalPulsePeriod: TimeInterval = 1.2
    static let criticalPulseCount = 3

    private var progression: MeterSettings.ProgressionMode {
        MeterSettings.ProgressionMode(rawValue: progressionMode) ?? .left
    }

    private var selectedWindow: MeterSettings.MenuBarWindow {
        MeterSettings.MenuBarWindow(rawValue: menuBarWindow) ?? .nearest
    }

    var body: some View {
        let accessibilitySummary = MenuBarText.accessibilitySummary(
            provider: appState.mainMeterProvider,
            reading: appState.mainMeterReading,
            progression: progression,
            selection: selectedWindow,
            isActive: appState.isActive,
            isStale: appState.mainMeterIsStale,
            isLoading: appState.mainMeterIsLoading,
            severity: appState.mainMeterSeverity,
            now: Date())
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .task(id: accessibilitySummary) {
            await MenuBarAccessibility.publish(accessibilitySummary)
        }
        .task(id: appState.mainMeterSeverity) {
            // Announce the change, then settle: a state that can last days must not
            // keep the status item redrawing.
            guard appState.mainMeterSeverity == .critical else {
                criticalPulseStart = nil
                return
            }
            criticalPulseStart = Date()
            let duration = Self.criticalPulsePeriod * Double(Self.criticalPulseCount)
            // A cancelled task must not clear the pulse of the task that replaced it.
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            criticalPulseStart = nil
        }
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
                if let start = criticalPulseStart, !reduceMotion {
                    pulsingDot(.pfEnergyEmpty, start: start)
                } else {
                    dot(.pfEnergyEmpty)
                }
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

    private func pulsingDot(_ color: Color, start: Date) -> some View {
        // Capped at 12 fps — an uncapped .animation schedule runs the status
        // item's display link at full refresh rate for a 1.2 s pulse.
        TimelineView(.animation(minimumInterval: 1 / 12)) { context in
            let t = context.date.timeIntervalSince(start)
            // 0…1…0 per period: each pulse starts and ends at the static dot.
            let phase = (1 - cos(t * 2 * .pi / Self.criticalPulsePeriod)) / 2
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

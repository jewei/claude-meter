import Foundation
import MeterDomain

/// What the status item shows: an icon, an optional badge, an optional number, and one spoken
/// summary for VoiceOver.
public struct MenuBarModel: Equatable, Sendable {
    public enum Icon: Equatable, Sendable {
        /// The bolt with its badge. Also the calm state with no data: before setup, while
        /// paused, or before the first reading.
        case bolt(Badge)
        /// The first reading is on its way.
        case loading
        /// The warning bolt: no reading because something failed (``MainMeter/hasFailure``).
        case error
    }

    public enum Badge: Equatable, Sendable {
        case none
        /// A dot colored by severity.
        case dot(Severity)
        /// A gray dot: the reading is old.
        case stale
        /// A red pill with "0": no energy left.
        case exhausted
    }

    public let icon: Icon
    /// `99% 5h`, `73% 7d`, or `99% 5h · 73% 7d`. Nil when paused or stale.
    public let text: String?
    /// Paused or not set up yet: the whole item is dimmed.
    public let isDimmed: Bool
    public let accessibilityLabel: String

    public init(_ context: PresentationContext) {
        let meter = MainMeter(context)
        let isSetUp = context.settings.hasCompletedOnboarding
        let isPaused = context.settings.isPaused || !isSetUp
        let selected = meter.selected
        isDimmed = isPaused

        if isPaused {
            icon = .bolt(.none)
        } else if selected == nil && meter.isLoading {
            icon = .loading
        } else if selected == nil {
            icon = meter.hasFailure ? .error : .bolt(.none)
        } else if meter.isStale {
            icon = .bolt(.stale)
        } else if meter.severity == .exhausted {
            icon = .bolt(.exhausted)
        } else {
            icon = .bolt(.dot(meter.severity))
        }

        let parts = selected.map { Self.parts(of: $0, context: context) } ?? []
        text =
            isPaused || meter.isStale || parts.isEmpty
            ? nil : parts.map(\.short).joined(separator: " · ")
        accessibilityLabel =
            isSetUp
            ? Self.summary(
                meter: meter, parts: parts, isPaused: isPaused, showsUsed: context.showsUsed)
            : "Claude Meter. Not set up."
    }

    private struct Part {
        let window: QuotaWindow
        let suffix: String
        let short: String
    }

    /// The windows that the menu-bar setting asks for. The session choice falls back to the
    /// weekly window when the account reports no session value.
    private static func parts(of account: AccountUsage, context: PresentationContext) -> [Part] {
        let session = account.bindingWindow(.session).flatMap { $0.usedPercent == nil ? nil : $0 }
        let weekly = account.bindingWindow(.weekly).flatMap { $0.usedPercent == nil ? nil : $0 }
        let windows: [(QuotaWindow, String)] =
            switch context.settings.appearance.menuBarWindow {
            case .session:
                [session.map { ($0, "5h") } ?? weekly.map { ($0, "7d") }].compactMap { $0 }
            case .weekly: [weekly.map { ($0, "7d") }].compactMap { $0 }
            case .both: [session.map { ($0, "5h") }, weekly.map { ($0, "7d") }].compactMap { $0 }
            }
        return windows.map { window, suffix in
            Part(
                window: window, suffix: suffix,
                short: "\(Formatting.percent(window, showsUsed: context.showsUsed)) \(suffix)")
        }
    }

    private static func summary(
        meter: MainMeter, parts: [Part], isPaused: Bool, showsUsed: Bool
    ) -> String {
        let title = "Claude Meter. \(meter.provider.displayName)."
        let refreshing = meter.isLoading ? " Refreshing." : ""
        if isPaused { return "\(title) Paused." }
        if meter.isStale { return "\(title) Data is stale.\(refreshing)" }
        guard meter.selected != nil else {
            return meter.isLoading ? "\(title) Loading." : "\(title) Usage unavailable."
        }
        let details = parts.map { part in
            let name = part.window.kind == .session ? "Session" : "Weekly"
            guard let value = Formatting.value(part.window, showsUsed: showsUsed) else {
                return "\(name) unavailable."
            }
            return
                "\(name) \(Formatting.wholePercent(value)) percent \(showsUsed ? "used" : "left")."
        }
        let status =
            switch meter.severity {
            case .normal: "Overall quota is normal."
            case .warning: "Overall quota warning."
            case .critical: "Overall quota is critical."
            case .exhausted: "Quota limit reached."
            case .unknown: "Overall quota status is unknown."
            }
        return ([title] + details + [status]).joined(separator: " ") + refreshing
    }
}

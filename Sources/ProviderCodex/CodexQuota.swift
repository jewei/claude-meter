import Foundation
import MeterDomain
import MeterPlatform

/// Quota from either Codex source, before it becomes an ``AccountUsage``.
struct CodexQuota: Equatable, Sendable {
    /// The position in which Codex reports a window.
    enum Slot: String, Sendable {
        case primary
        case secondary
    }

    struct Window: Equatable, Sendable {
        let usedPercent: Double?
        let resetsAt: Date?
        /// The window length in seconds. Nil when unknown, not positive, or not finite.
        let duration: TimeInterval?

        init(usedPercent: Double?, resetsAt: Date?, duration: TimeInterval?) {
            self.usedPercent = usedPercent.flatMap { $0.isFinite ? $0 : nil }
            self.resetsAt = DateBounds.validated(resetsAt)
            self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
    }

    /// Windows of at most this length are session windows; longer ones are weekly.
    static let sessionLimit: TimeInterval = 86_400

    var primary: Window?
    var secondary: Window?
    var credits: Balance?
    /// The plan as Codex names it, such as `plus`.
    var plan: String?
    /// The number of reset credits that Codex reports. Nil when it reports none.
    var resetCount: Int?
    /// Details for some or all reset credits.
    var resets: [ResetAllowance.Reset] = []

    /// One rule for both sources: a reading needs a window or credits. Plan and reset metadata
    /// alone are not usage.
    var hasUsage: Bool {
        primary != nil || secondary != nil || credits != nil
    }

    func usage(for home: CodexHome, observedAt: Date, owner: AccountOwner?) -> AccountUsage {
        let windows = [
            primary.map { Self.quotaWindow($0, slot: .primary) },
            secondary.map { Self.quotaWindow($0, slot: .secondary) },
        ]
        return AccountUsage(
            id: home.id,
            name: home.name,
            plan: CodexPlan.displayName(plan),
            windows: windows.compactMap { $0 },
            balances: credits.map { [$0] } ?? [],
            resetAllowance: resetCount.map { ResetAllowance(available: $0, resets: resets) },
            observedAt: observedAt,
            attemptedAt: observedAt,
            owner: owner)
    }

    /// The duration decides the kind. The position decides only when the duration is unknown.
    static func kind(of window: Window, slot: Slot) -> QuotaWindow.Kind {
        if let duration = window.duration {
            return duration > sessionLimit ? .weekly : .session
        }
        return slot == .primary ? .session : .weekly
    }

    static func quotaWindow(_ window: Window, slot: Slot) -> QuotaWindow {
        let kind = kind(of: window, slot: slot)
        return QuotaWindow(
            id: slot.rawValue, title: title(kind: kind), kind: kind,
            usedPercent: window.usedPercent, resetsAt: window.resetsAt)
    }

    /// "Session" or "Weekly", matching Claude, so the hero and cards read the same for both
    /// providers. Never a limit ID.
    static func title(kind: QuotaWindow.Kind) -> String {
        kind == .session ? "Session" : "Weekly"
    }

    /// Credits from either source. Malformed credits are nil and never discard windows.
    static func credits(from value: JSONValue?) -> Balance? {
        guard let fields = value?.objectValue else { return nil }
        if fields["unlimited"]?.boolValue == true {
            return Balance(kind: .credits, amount: nil, unit: .credits, isUnlimited: true)
        }
        guard let amount = fields["balance"]?.decimalValue else { return nil }
        return Balance(kind: .credits, amount: amount, unit: .credits)
    }
}

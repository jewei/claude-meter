import Foundation
import MeterDomain

/// Everything a presentation builder may read, captured at one instant.
///
/// Builders are pure: the same context always gives the same model. Views build a context
/// on each render with the current time, so countdowns and staleness stay live.
public struct PresentationContext: Sendable {
    /// An observation older than this is stale, even when the last refresh succeeded. It leaves
    /// one full refresh interval of headroom.
    public static let staleAfter: TimeInterval = 600
    /// Clock skew allowed before a future observation counts as invalid.
    public static let futureTolerance: TimeInterval = 300

    public var settings: Settings
    public var readings: [ProviderID: Reading<ProviderUsage>]
    public var histories: [ProviderID: Reading<ProviderTokenHistory>]
    public var refreshing: Set<ProviderID>
    public var refreshingHistory: Set<ProviderID>
    public var now: Date
    public var calendar: Calendar
    public var isUpdateAvailable: Bool

    public init(
        settings: Settings,
        readings: [ProviderID: Reading<ProviderUsage>] = [:],
        histories: [ProviderID: Reading<ProviderTokenHistory>] = [:],
        refreshing: Set<ProviderID> = [],
        refreshingHistory: Set<ProviderID> = [],
        now: Date,
        calendar: Calendar = .current,
        isUpdateAvailable: Bool = false
    ) {
        self.settings = settings
        self.readings = readings
        self.histories = histories
        self.refreshing = refreshing
        self.refreshingHistory = refreshingHistory
        self.now = now
        self.calendar = calendar
        self.isUpdateAvailable = isUpdateAvailable
    }

    public var thresholds: Thresholds { settings.appearance.thresholds }
    public var showsUsed: Bool { settings.appearance.meterMode == .used }

    /// The provider that owns the menu bar. Settings can hold only Claude or Codex.
    public var mainProvider: ProviderID {
        settings.menuBar.provider.canOwnMenuBar ? settings.menuBar.provider : .claude
    }

    public func isEnabled(_ provider: ProviderID) -> Bool {
        settings.enabledProviders.contains(provider)
    }

    /// The accounts of an enabled provider as they apply now: display names and plan
    /// overrides applied, staleness combined, and windows resolved.
    public func accounts(for provider: ProviderID) -> [AccountUsage] {
        guard isEnabled(provider), let reading = readings[provider], let value = reading.value
        else { return [] }
        return value.accounts.map { account in
            var account = account
            account.name =
                settings.displayName(for: provider, account: account.id)
                ?? Self.friendlyName(account.name)
            if provider == .claude, account.plan == nil {
                account.plan = settings.claude.planOverrides[account.id]
            }
            return account.resolved(at: now, isStale: isStale(account, reading: reading))
        }
    }

    /// Stale when the source says so, the last refresh failed, or the observation is old.
    func isStale(_ account: AccountUsage, reading: Reading<ProviderUsage>) -> Bool {
        if account.isStale || reading.isStale { return true }
        guard let observedAt = account.observedAt else { return false }
        let age = now.timeIntervalSince(observedAt)
        return !age.isFinite || age < -Self.futureTolerance || age > Self.staleAfter
    }

    /// `it-oneone` → `It Oneone`, `default` → `Default`.
    static func friendlyName(_ label: String) -> String {
        label.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

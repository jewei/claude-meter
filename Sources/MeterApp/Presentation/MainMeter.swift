import Foundation
import MeterDomain

/// The account that owns the menu bar, the hero, and the first card.
public struct MainMeter: Equatable, Sendable {
    public let provider: ProviderID
    /// Presentation accounts of the provider, in provider order.
    public let accounts: [AccountUsage]
    public let selected: AccountUsage?
    /// Why nothing is selected, or the selected account's own issue.
    public let issue: UsageIssue?
    /// The issue is a failure: a failed refresh, an account's own issue, or a missing pinned
    /// account. False when nothing was read yet or no main-capable provider is in use, which
    /// are not errors.
    public let hasFailure: Bool
    /// The highest severity of the pinned account, or of every account without a pin.
    public let severity: Severity
    /// A refresh of the provider is in flight.
    public let isRefreshing: Bool
    /// The first reading is on its way
    /// (``PresentationContext/isLoadingFirstReading(_:)``).
    public let isLoadingFirstReading: Bool

    /// The selected account shows as stale (see ``PresentationContext/isStale(_:reading:)``).
    public var isStale: Bool { selected?.isStale ?? false }

    /// Builds the main meter. An exact pin never falls back to another account, and a missing
    /// selection never falls back to another provider.
    public init(_ context: PresentationContext) {
        let provider = context.mainProvider
        let name = provider.displayName
        self.provider = provider
        isRefreshing = context.refreshing.contains(provider)
        isLoadingFirstReading = context.isLoadingFirstReading(provider)
        guard context.isEnabled(provider) else {
            accounts = []
            selected = nil
            severity = .unknown
            hasFailure = false
            issue =
                provider == .claude && context.settings.claude.needsConnection
                ? UsageIssue("Connect Claude in Settings > Data.", needsAction: true)
                : UsageIssue("\(name) is off. Turn it on in Settings > Data.", needsAction: true)
            return
        }
        let accounts = context.accounts(for: provider)
        let pin = context.settings.menuBar.pinnedAccounts[provider]
        let selected = AccountSelection.primary(in: accounts, pinned: pin)
        self.accounts = accounts
        self.selected = selected

        let considered = pin.map { pin in accounts.filter { $0.id == pin } } ?? accounts
        severity =
            considered.filter(\.hasObservation).map { $0.severity(context.thresholds) }.max()
            ?? .unknown

        (issue, hasFailure) = Self.issue(
            provider: provider, accounts: accounts, pin: pin, selected: selected,
            readingIssue: context.readings[provider]?.issue)
    }

    /// The issue to state, and whether it is a failure.
    private static func issue(
        provider: ProviderID, accounts: [AccountUsage], pin: AccountID?,
        selected: AccountUsage?, readingIssue: UsageIssue?
    ) -> (UsageIssue?, Bool) {
        let name = provider.displayName
        if let pin {
            guard let pinned = accounts.first(where: { $0.id == pin }) else {
                let missing = UsageIssue("The selected \(name) account is no longer configured.")
                return (readingIssue ?? missing, true)
            }
            if let issue = pinned.issue ?? readingIssue { return (issue, true) }
            return selected == nil
                ? (UsageIssue("The selected \(name) account has no usage reading."), false)
                : (nil, false)
        }
        if let issue = selected?.issue ?? readingIssue { return (issue, true) }
        guard selected == nil else { return (nil, false) }
        if let issue = accounts.lazy.compactMap(\.issue).first { return (issue, true) }
        return (UsageIssue("\(name) has no usage reading yet."), false)
    }

    /// The card that the main meter owns.
    public var cardID: CardID? {
        selected.map { .account(provider, $0.id) }
    }
}

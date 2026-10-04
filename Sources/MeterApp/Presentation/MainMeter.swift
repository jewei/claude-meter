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
    /// The highest severity of the pinned account, or of every account without a pin.
    public let severity: Severity
    public let isLoading: Bool

    public var isStale: Bool { selected?.isStale ?? false }

    /// Builds the main meter. An exact pin never falls back to another account, and a missing
    /// selection never falls back to another provider.
    public init(_ context: PresentationContext) {
        let provider = context.mainProvider
        let name = provider.displayName
        self.provider = provider
        isLoading = context.refreshing.contains(provider)
        guard context.isEnabled(provider) else {
            accounts = []
            selected = nil
            severity = .unknown
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

        issue = Self.issue(
            provider: provider, accounts: accounts, pin: pin, selected: selected,
            readingIssue: context.readings[provider]?.issue)
    }

    private static func issue(
        provider: ProviderID, accounts: [AccountUsage], pin: AccountID?,
        selected: AccountUsage?, readingIssue: UsageIssue?
    ) -> UsageIssue? {
        let name = provider.displayName
        if let pin {
            guard let pinned = accounts.first(where: { $0.id == pin }) else {
                return readingIssue
                    ?? UsageIssue("The selected \(name) account is no longer configured.")
            }
            if let issue = pinned.issue ?? readingIssue { return issue }
            return selected == nil
                ? UsageIssue("The selected \(name) account has no usage reading.") : nil
        }
        if let issue = selected?.issue ?? readingIssue { return issue }
        guard selected == nil else { return nil }
        return accounts.lazy.compactMap(\.issue).first
            ?? UsageIssue("\(name) has no usage reading yet.")
    }

    /// The card that the main meter owns.
    public var cardID: CardID? {
        selected.map { .account(provider, $0.id) }
    }
}

import Foundation
import MeterDomain

/// The account that owns the menu bar, the hero, and the first card.
public struct MainMeter: Equatable, Sendable {
    /// The account that the meter shows, or why it shows none.
    public enum Selection: Equatable, Sendable {
        case account(AccountUsage)
        /// No account: the meter is unavailable for this reason.
        case unavailable(UsageIssue)
    }

    public let provider: ProviderID
    /// Presentation accounts of the provider, in provider order.
    public let accounts: [AccountUsage]
    public let selection: Selection
    /// Why nothing is selected, or the selected account's own issue.
    public let issue: UsageIssue?
    /// The issue is a failure: a failed refresh, an account's own issue, or a missing pinned
    /// account. False when nothing was read yet (also with a pin, and with a pin that only the
    /// reading saved by an earlier launch lacks) or no main-capable provider is in use, which
    /// are not errors.
    public let hasFailure: Bool
    /// The highest severity of the pinned account, or of every account without a pin.
    public let severity: Severity
    /// A refresh of the provider is in flight.
    public let isRefreshing: Bool
    /// The first reading is on its way
    /// (``PresentationContext/isLoadingFirstReading(_:)``), also the first reading of a pinned
    /// account that the reading saved by an earlier launch lacks.
    public let isLoadingFirstReading: Bool

    /// The account that the meter shows; nil when it is unavailable.
    public var selected: AccountUsage? {
        guard case .account(let account) = selection else { return nil }
        return account
    }

    /// The selected account shows as stale (see ``PresentationContext/isStale(_:reading:)``).
    public var isStale: Bool { selected?.isStale ?? false }

    /// Builds the main meter. An exact pin never falls back to another account, and a missing
    /// selection never falls back to another provider.
    public init(_ context: PresentationContext) {
        let provider = context.mainProvider
        let name = provider.displayName
        self.provider = provider
        let isRefreshing = context.refreshing.contains(provider)
        self.isRefreshing = isRefreshing
        guard context.isEnabled(provider) else {
            let reason =
                provider == .claude && context.settings.claude.needsConnection
                ? UsageIssue("Connect Claude in Settings > Data.", needsAction: true)
                : UsageIssue("\(name) is off. Turn it on in Settings > Data.", needsAction: true)
            accounts = []
            selection = .unavailable(reason)
            issue = reason
            hasFailure = false
            severity = .unknown
            isLoadingFirstReading = context.isLoadingFirstReading(provider)
            return
        }
        let accounts = context.accounts(for: provider)
        let pin = context.settings.menuBar.pinnedAccounts[provider]
        let reading = context.readings[provider]
        self.accounts = accounts
        // The archive saves only accounts with an identity owner, so a saved reading that
        // lacks the pinned account cannot show that it is gone. The pin waits for the first
        // refresh, as before any reading.
        let awaitsPin =
            pin.map { pin in
                context.restored.contains(provider) && !accounts.contains { $0.id == pin }
            } ?? false
        isLoadingFirstReading =
            context.isLoadingFirstReading(provider) || (awaitsPin && isRefreshing)

        let considered = pin.map { pin in accounts.filter { $0.id == pin } } ?? accounts
        severity =
            considered.filter(\.hasObservation).map { $0.severity(context.thresholds) }.max()
            ?? .unknown

        // A pin selects only its own account, so a selected account is the pinned one.
        if let selected = AccountSelection.primary(in: accounts, pinned: pin) {
            selection = .account(selected)
            issue = selected.issue ?? reading?.issue
            hasFailure = issue != nil
        } else {
            let (reason, isFailure) = Self.reason(
                provider: provider, accounts: accounts, pin: pin, reading: reading,
                awaitsPin: awaitsPin)
            selection = .unavailable(reason)
            issue = reason
            hasFailure = isFailure
        }
    }

    /// Why no account is selected, and whether that is a failure.
    private static func reason(
        provider: ProviderID, accounts: [AccountUsage], pin: AccountID?,
        reading: Reading<ProviderUsage>?, awaitsPin: Bool
    ) -> (UsageIssue, Bool) {
        let name = provider.displayName
        let noReading = UsageIssue("\(name) has no usage reading yet.")
        // Before the first reading (a launch without a saved one, a source switched on, or a
        // reconnect), a pin cannot be missing yet: nothing was read to look for it in. A
        // reading saved by an earlier launch that lacks the pin cannot show it either.
        guard let reading, !awaitsPin else { return (noReading, false) }
        if let pin {
            guard let pinned = accounts.first(where: { $0.id == pin }) else {
                let missing = UsageIssue("The selected \(name) account is no longer configured.")
                return (reading.issue ?? missing, true)
            }
            if let issue = pinned.issue ?? reading.issue { return (issue, true) }
            return (UsageIssue("The selected \(name) account has no usage reading."), false)
        }
        if let issue = reading.issue ?? accounts.lazy.compactMap(\.issue).first {
            return (issue, true)
        }
        return (noReading, false)
    }

    /// The card that the main meter owns.
    public var cardID: CardID? {
        selected.map { .account(provider, $0.id) }
    }
}

import Foundation
import MeterDomain

/// Builds the "Tokens used" section for one card.
struct TokenRowsBuilder {
    let context: PresentationContext

    func model(provider: ProviderID, account: AccountID) -> TokenRowsModel? {
        guard context.isEnabled(provider) else { return nil }
        let reading = context.histories[provider]
        // The history says where its counts come from; before the first one, the provider's
        // usual source.
        let source = reading?.value?.source ?? (provider == .cursor ? .account : .thisMac)
        let isAccountSource = source == .account
        let history = reading?.value?.history(for: account)
        // Each period's estimate first; the rows and the note both use them.
        let rows = TokenPeriod.allCases.map { period in
            let count = history?.tokens(in: period, now: context.now, calendar: context.calendar)
            let estimate =
                count == nil
                ? nil : history?.cost(in: period, now: context.now, calendar: context.calendar)
            return Self.row(period, count: count, estimate: estimate)
        }
        return TokenRowsModel(
            sourceLabel: isAccountSource ? "Account usage" : "This Mac",
            help: isAccountSource
                ? "Token records reported by \(provider.displayName) for this account."
                : "Local sessions in this account's folder on this Mac, including earlier logins "
                    + "that used the folder. Other folders and devices are not included.",
            rows: rows,
            note: note(
                reading: reading, history: history, provider: provider,
                isAccountSource: isAccountSource))
    }

    private func note(
        reading: Reading<ProviderTokenHistory>?, history: TokenHistory?, provider: ProviderID,
        isAccountSource: Bool
    ) -> String? {
        if let issue = reading?.issue { return NoticeText.text(for: issue, now: context.now) }
        guard let history else {
            return context.refreshingHistory.contains(provider)
                ? "Reading token usage…" : "Token usage unavailable"
        }
        if history.isPartial { return "Partial history · some records could not be counted" }
        if !history.hasRecords {
            return isAccountSource ? "No token records" : "No local token records"
        }
        let age = context.now.timeIntervalSince(history.observedAt)
        let isOld =
            age > context.staleAfter
            || history.timeZoneID != context.calendar.timeZone.identifier
            || !context.calendar.isDate(history.observedAt, inSameDayAs: context.now)
        if isOld { return "Token data may be stale" }
        return priceNote(history)
    }

    private static func row(
        _ period: TokenPeriod, count: Int64?, estimate: CostEstimate?
    ) -> TokenRowsModel.Row {
        guard let count else {
            return TokenRowsModel.Row(
                title: period.title, value: "—", accessibilityValue: "Unavailable",
                help: "Token count unavailable")
        }
        guard let estimate else {
            return TokenRowsModel.Row(
                title: period.title, value: Formatting.tokens(count),
                accessibilityValue: "\(count) tokens",
                help: "\(count.formatted()) tokens, including cache tokens")
        }
        return TokenRowsModel.Row(
            title: period.title,
            value: "\(Formatting.tokens(count)) · \(Formatting.estimate(estimate))",
            accessibilityValue: "\(count) tokens, \(Formatting.spokenEstimate(estimate))",
            help: "\(count.formatted()) tokens, including cache tokens. "
                + "Estimated at API list prices. Not a bill.")
    }

    /// Why some tokens have no estimate. It covers the widest row (Last 7 Days), which
    /// contains the others, and shows whenever the rows show token counts, so a new model
    /// that is not in the price table still explains the missing estimate.
    private func priceNote(_ history: TokenHistory) -> String? {
        guard
            let unpriced = history.unpricedTokens(
                in: .lastSevenDays, now: context.now, calendar: context.calendar),
            unpriced > 0
        else { return nil }
        let names = history.unpricedModels.sorted()
        guard !names.isEmpty else { return "Some tokens have no price" }
        let shown = names.prefix(3).joined(separator: ", ")
        let more = names.count > 3 ? " and \(names.count - 3) more" : ""
        return Redactor.redact("No price for: \(shown)\(more)")
    }
}

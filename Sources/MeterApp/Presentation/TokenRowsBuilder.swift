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
        let rows = TokenPeriod.allCases.map { period in
            let count = history?.tokens(in: period, now: context.now, calendar: context.calendar)
            return TokenRowsModel.Row(
                title: period.title,
                value: count.map(Formatting.tokens) ?? "—",
                accessibilityValue: count.map { "\($0) tokens" } ?? "Unavailable",
                help: count.map { "\($0.formatted()) tokens, including cache tokens" }
                    ?? "Token count unavailable")
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
            age > PresentationContext.staleAfter
            || history.timeZoneID != context.calendar.timeZone.identifier
            || !context.calendar.isDate(history.observedAt, inSameDayAs: context.now)
        return isOld ? "Token data may be stale" : nil
    }
}

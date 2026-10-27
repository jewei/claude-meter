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
        let note = note(
            reading: reading, history: history, provider: provider,
            isAccountSource: isAccountSource)
        var footnote: [TokenRowsModel.FootnotePart] = []
        if rows.contains(where: \.hasEstimate) {
            footnote.append(.text("Estimated at API list prices, not a bill."))
        }
        if let note {
            if note.explainsIncomplete, rows.contains(where: \.row.isIncomplete) {
                footnote.append(.mark)
            }
            footnote.append(.text(note.text))
        }
        return TokenRowsModel(
            sourceLabel: isAccountSource ? "Account usage" : "This Mac",
            help: isAccountSource
                ? "Token records reported by \(provider.displayName) for this account."
                : "Local sessions in this account's folder on this Mac, including earlier logins "
                    + "that used the folder. Other folders and devices are not included.",
            rows: rows.map(\.row), note: note?.text, footnote: footnote)
    }

    /// The note, and whether it says why an estimate can be incomplete.
    private func note(
        reading: Reading<ProviderTokenHistory>?, history: TokenHistory?, provider: ProviderID,
        isAccountSource: Bool
    ) -> (text: String, explainsIncomplete: Bool)? {
        if let issue = reading?.issue {
            return (NoticeText.text(for: issue, now: context.now), false)
        }
        guard let history else {
            return context.refreshingHistory.contains(provider)
                ? ("Reading token usage…", false) : ("Token usage unavailable", false)
        }
        if history.isPartial {
            return ("Partial history — some records couldn't be counted", true)
        }
        if !history.hasRecords {
            return (isAccountSource ? "No token records" : "No local token records", false)
        }
        let age = context.now.timeIntervalSince(history.observedAt)
        let isOld =
            age > context.staleAfter
            || history.timeZoneID != context.calendar.timeZone.identifier
            || !context.calendar.isDate(history.observedAt, inSameDayAs: context.now)
        if isOld { return ("Token data may be stale", false) }
        return priceNote(history).map { ($0, true) }
    }

    private static func row(
        _ period: TokenPeriod, count: Int64?, estimate: CostEstimate?
    ) -> (row: TokenRowsModel.Row, hasEstimate: Bool) {
        guard let count else {
            let row = TokenRowsModel.Row(
                title: period.title, value: "—", isIncomplete: false, detail: nil,
                accessibilityValue: "Unavailable", help: "Token count unavailable")
            return (row, false)
        }
        guard let estimate else {
            let row = TokenRowsModel.Row(
                title: period.title, value: Formatting.compactCount(count), isIncomplete: false,
                detail: count == 1 ? "token" : "tokens", accessibilityValue: "\(count) tokens",
                help: "\(count.formatted()) tokens, including cache tokens")
            return (row, false)
        }
        let row = TokenRowsModel.Row(
            title: period.title, value: Formatting.estimateAmount(estimate),
            isIncomplete: !estimate.isComplete, detail: Formatting.tokens(count),
            accessibilityValue: "\(count) tokens, \(Formatting.spokenEstimate(estimate))",
            help: "\(count.formatted()) tokens, including cache tokens. "
                + "Estimated at API list prices. Not a bill.")
        return (row, true)
    }

    /// Why some tokens have no estimate. It covers the widest row (Last 7 days), which
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

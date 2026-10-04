import Foundation
import MeterDomain

/// Builds the "Usage limit resets" section.
enum ResetsBuilder {
    static func model(_ allowance: ResetAllowance?, now: Date) -> ResetsModel {
        guard let allowance else {
            return ResetsModel(countText: "Not reported", rows: [], note: nil, summary: nil)
        }
        let rows =
            allowance.available == 0
            ? []
            : allowance.resets.map { reset in
                ResetsModel.Row(
                    title: reset.title,
                    expiryText: expiryText(reset.expiresAt, now: now),
                    help: reset.expiresAt.map {
                        "Expires \($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? "Expiry date not provided")
            }
        let note: String? =
            if allowance.available == 0 {
                nil
            } else if rows.isEmpty {
                "Expiry details unavailable"
            } else if rows.count < allowance.available {
                "Expiry details shown for \(rows.count) of \(allowance.available) resets"
            } else {
                nil
            }
        let count = allowance.available
        return ResetsModel(
            countText: "\(count) available", rows: rows, note: note,
            summary: count == 0
                ? nil : "\(count) usage \(count == 1 ? "reset" : "resets") available")
    }

    private static func expiryText(_ date: Date?, now: Date) -> String {
        guard let date else { return "Expiry date not provided" }
        guard let countdown = Countdown.text(until: date, now: now) else { return "Expired" }
        return "Expires in \(countdown)"
    }
}

/// Builds the "Tokens used" section for one card.
struct TokenRowsBuilder {
    let context: PresentationContext

    func model(provider: ProviderID, account: AccountID) -> TokenRowsModel? {
        guard context.isEnabled(provider) else { return nil }
        let reading = context.histories[provider]
        let isAccountSource = provider == .cursor
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
                ? "Token records reported by Cursor for this account."
                : "Local sessions in this account's folder on this Mac, including earlier logins "
                    + "that used the folder. Other folders and devices are not included.",
            rows: rows,
            note: note(reading: reading, history: history, provider: provider))
    }

    private func note(
        reading: Reading<ProviderTokenHistory>?, history: TokenHistory?, provider: ProviderID
    ) -> String? {
        if let issue = reading?.issue { return issue.message }
        guard let history else {
            return context.refreshingHistory.contains(provider)
                ? "Reading token usage…" : "Token usage unavailable"
        }
        if history.isPartial { return "Partial history · some records could not be counted" }
        if !history.hasRecords {
            return provider == .cursor ? "No token records" : "No local token records"
        }
        let age = context.now.timeIntervalSince(history.observedAt)
        let isOld =
            age > PresentationContext.staleAfter
            || history.timeZoneID != context.calendar.timeZone.identifier
            || !context.calendar.isDate(history.observedAt, inSameDayAs: context.now)
        return isOld ? "Token data may be stale" : nil
    }
}

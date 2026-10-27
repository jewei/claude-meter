import Foundation
import MeterPlatform

/// Claude API list prices, for the cost estimate of local history (`docs/token-history.md`,
/// "Cost estimate"). The table changes only with a release: check it before each one
/// (`docs/releasing.md`). A model that is not here has no price; the app never guesses.
///
/// Source: https://platform.claude.com/docs/en/about-claude/pricing, checked 2026-10-27.
/// Cache writes cost 1.25 times the input rate for 5 minutes and 2 times for 1 hour on every
/// model; cache reads have their own rate per model.
enum ClaudePrices {
    /// US dollars per million tokens.
    struct Rates: Equatable, Sendable {
        let input: Decimal
        let fiveMinuteWrite: Decimal
        let oneHourWrite: Decimal
        let read: Decimal
        let output: Decimal

        init(input: String, read: String, output: String) {
            self.input = Decimal(string: input) ?? 0
            fiveMinuteWrite = self.input * 5 / 4
            oneHourWrite = self.input * 2
            self.read = Decimal(string: read) ?? 0
            self.output = Decimal(string: output) ?? 0
        }
    }

    struct Price: Equatable, Sendable {
        let rates: Rates
        /// A prompt (input plus cache tokens) above this many tokens uses ``longContext``.
        var longContextThreshold: Int64?
        var longContext: Rates?
        /// Fast mode multiplies every rate. Nil when the model has no fast mode.
        var fastMultiplier: Decimal?
    }

    static let table: [String: Price] = [
        "claude-fable-5-1": Price(rates: Rates(input: "10", read: "0.25", output: "50")),
        "claude-fable-5": Price(rates: Rates(input: "10", read: "1", output: "50")),
        "claude-opus-5-5": Price(
            rates: Rates(input: "4", read: "0.2", output: "20"), fastMultiplier: 2),
        "claude-opus-5": Price(
            rates: Rates(input: "5", read: "0.5", output: "25"), fastMultiplier: 2),
        "claude-opus-4-8": Price(
            rates: Rates(input: "5", read: "0.5", output: "25"), fastMultiplier: 2),
        "claude-opus-4-7": Price(rates: Rates(input: "5", read: "0.5", output: "25")),
        "claude-opus-4-6": Price(rates: Rates(input: "5", read: "0.5", output: "25")),
        "claude-sonnet-5-5": Price(rates: Rates(input: "2", read: "0.1", output: "10")),
        "claude-sonnet-5": Price(rates: Rates(input: "2", read: "0.2", output: "10")),
        "claude-sonnet-4-6": Price(rates: Rates(input: "3", read: "0.3", output: "15")),
        // Priced by prompt length: a prompt over 100,000 tokens pays the higher rates.
        "claude-haiku-5-5": Price(
            rates: Rates(input: "0.1", read: "0.01", output: "0.5"),
            longContextThreshold: 100_000,
            longContext: Rates(input: "0.5", read: "0.05", output: "2.5")),
        "claude-haiku-4-5": Price(rates: Rates(input: "1", read: "0.1", output: "5")),
    ]

    /// The price of `model`, matched exactly after ``normalized(_:)``.
    static func price(for model: String) -> Price? {
        table[normalized(model)]
    }

    /// Lowercase, without a leading `anthropic/` and without a trailing date such as
    /// `-20250514`. No fuzzy matching: a wrong price is worse than none.
    static func normalized(_ model: String) -> String {
        var name = model.lowercased()
        if name.hasPrefix("anthropic/") { name.removeFirst("anthropic/".count) }
        if let match = name.firstMatch(of: /-\d{8}$/) {
            name.removeSubrange(match.range)
        }
        return name
    }
}

extension ClaudePrices {
    /// The record of one response: its tokens, and their cost when the model and every part
    /// have a price. A record without a price counts all its tokens as unpriced.
    static func record(
        date: Date, count: Int64, usage: ClaudeLogLine.Usage, model: String?
    ) -> TokenRecord {
        let unpriced = TokenRecord(
            date: date, count: count, unpricedTokens: count, unpricedModel: unpricedName(model))
        guard let model, var price = price(for: model),
            let input = usage.input?.value, let output = usage.output?.value,
            let read = HistoryJSON.Count.orZero(usage.cacheRead),
            let writes = usage.cacheWrites,
            let prompt = TokenRecord.sum([input, read, writes.fiveMinutes, writes.oneHour])
        else { return unpriced }
        var multiplier: Decimal = 1
        if usage.speed?.value == "fast" {
            guard let fast = price.fastMultiplier else { return unpriced }
            multiplier = fast
        }
        if let threshold = price.longContextThreshold, prompt > threshold,
            let long = price.longContext
        {
            price = Price(rates: long)
        }
        let rates = price.rates
        let dollars =
            Decimal(input) * rates.input + Decimal(output) * rates.output + Decimal(read)
            * rates.read + Decimal(writes.fiveMinutes) * rates.fiveMinuteWrite
            + Decimal(writes.oneHour) * rates.oneHourWrite
        return TokenRecord(date: date, count: count, cost: dollars * multiplier / 1_000_000)
    }

    /// `model` when the table has no price for it, for the price note.
    static func unpricedName(_ model: String?) -> String? {
        model.flatMap { price(for: $0) == nil ? $0 : nil }
    }
}

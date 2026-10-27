import Foundation
import MeterPlatform

/// OpenAI API list prices of the models that Codex uses, for the cost estimate of local
/// history (`docs/token-history.md`, "Cost estimate"). The table changes only with a release:
/// check it before each one (`docs/releasing.md`). A model that is not here has no price.
///
/// Source: https://developers.openai.com/api/docs/pricing, checked 2026-10-27, standard tier.
/// Codex logs do not say whether a cache write lasts 30 minutes or 12 hours, which OpenAI
/// prices differently, or whether a request ran in the fast tier. So cache writes have no
/// price, and every request uses the standard rate: the estimate can be low.
enum CodexPrices {
    /// US dollars per million tokens.
    struct Rates: Equatable, Sendable {
        let input: Decimal
        let cachedInput: Decimal
        let output: Decimal

        init(input: String, cachedInput: String, output: String) {
            self.input = Decimal(string: input) ?? 0
            self.cachedInput = Decimal(string: cachedInput) ?? 0
            self.output = Decimal(string: output) ?? 0
        }
    }

    struct Price: Equatable, Sendable {
        let rates: Rates
        /// Rates for a request with more than ``longContextThreshold`` input tokens.
        var longContext: Rates?
    }

    /// A request with more input tokens than this uses the long-context rates.
    static let longContextThreshold: Int64 = 272_000

    static let table: [String: Price] = [
        "gpt-6-astra": Price(
            rates: Rates(input: "10", cachedInput: "1", output: "50"),
            longContext: Rates(input: "20", cachedInput: "2", output: "75")),
        "gpt-6.1-sol": Price(
            rates: Rates(input: "2", cachedInput: "0.1", output: "10"),
            longContext: Rates(input: "4", cachedInput: "0.2", output: "15")),
        "gpt-6.1-terra": Price(
            rates: Rates(input: "1", cachedInput: "0.05", output: "5"),
            longContext: Rates(input: "2", cachedInput: "0.1", output: "7.5")),
        "gpt-6-sol": Price(
            rates: Rates(input: "2", cachedInput: "0.2", output: "10"),
            longContext: Rates(input: "4", cachedInput: "0.4", output: "15")),
        "gpt-6-luna": Price(
            rates: Rates(input: "0.1", cachedInput: "0.01", output: "0.5"),
            longContext: Rates(input: "0.2", cachedInput: "0.02", output: "0.75")),
        "gpt-5.6-sol": Price(
            rates: Rates(input: "4", cachedInput: "0.4", output: "20"),
            longContext: Rates(input: "8", cachedInput: "0.8", output: "30")),
        "gpt-5.6-terra": Price(
            rates: Rates(input: "2", cachedInput: "0.2", output: "12"),
            longContext: Rates(input: "4", cachedInput: "0.4", output: "18")),
        "gpt-5.6-luna": Price(
            rates: Rates(input: "0.2", cachedInput: "0.02", output: "1.2"),
            longContext: Rates(input: "0.4", cachedInput: "0.04", output: "1.8")),
        "gpt-5.5": Price(
            rates: Rates(input: "5", cachedInput: "0.5", output: "30"),
            longContext: Rates(input: "10", cachedInput: "1", output: "45")),
        "gpt-5.4": Price(
            rates: Rates(input: "2.5", cachedInput: "0.25", output: "15"),
            longContext: Rates(input: "5", cachedInput: "0.5", output: "22.5")),
        "gpt-5.3-codex": Price(rates: Rates(input: "1.75", cachedInput: "0.175", output: "14")),
    ]

    /// The price of `model`, matched exactly after ``normalized(_:)``.
    static func price(for model: String) -> Price? {
        table[normalized(model)]
    }

    /// Lowercase, without a leading `openai/` and without a trailing date such as
    /// `-2026-08-14`. No fuzzy matching: a wrong price is worse than none.
    static func normalized(_ model: String) -> String {
        var name = model.lowercased()
        if name.hasPrefix("openai/") { name.removeFirst("openai/".count) }
        if let match = name.firstMatch(of: /-\d{4}-\d{2}-\d{2}$/) {
            name.removeSubrange(match.range)
        }
        return name
    }

    /// The record of one response. Only a delta that is exactly one response's usage is
    /// priced (`CounterWalk`); its cache parts must fit inside its input.
    static func record(
        date: Date, counts: CodexTokenCounts, cache: CodexCacheParts?, model: String?
    ) -> TokenRecord? {
        guard let count = counts.total else { return nil }
        let unpriced = TokenRecord(date: date, count: count, unpricedTokens: count, model: model)
        guard let model, let price = price(for: model) else { return unpriced }
        let rates =
            counts.input > longContextThreshold ? price.longContext ?? price.rates : price.rates
        var dollars = Decimal(counts.output) * rates.output
        var unpricedTokens: Int64 = 0
        // A missing breakdown is zero; an invalid one (nil) cannot split the input.
        if let cache, let parts = TokenRecord.sum([cache.cachedInput, cache.cacheWrite]),
            parts <= counts.input
        {
            let uncached = counts.input - parts
            dollars +=
                Decimal(uncached) * rates.input + Decimal(cache.cachedInput)
                * rates.cachedInput
            unpricedTokens = cache.cacheWrite
        } else {
            // The breakdown does not fit the input, so the input has no price.
            unpricedTokens = counts.input
        }
        return TokenRecord(
            date: date, count: count, cost: dollars / 1_000_000, unpricedTokens: unpricedTokens,
            model: model)
    }
}

/// The cache parts of one usage object. Both are parts of `input_tokens`.
struct CodexCacheParts: Hashable, Sendable {
    static let zero = CodexCacheParts(cachedInput: 0, cacheWrite: 0)

    let cachedInput: Int64
    let cacheWrite: Int64
}

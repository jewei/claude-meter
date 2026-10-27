import Foundation

/// Tokens that one local record reports, at the time the record was written.
public struct TokenRecord: Hashable, Sendable {
    public let date: Date
    public let count: Int64
    /// The estimated cost of the priced part, in US dollars. Nil when no part has a price.
    public let cost: Decimal?
    /// Tokens of this record that have no price.
    public let unpricedTokens: Int64
    /// A model that has no price in the provider's table, for the price note. Nil for a model
    /// that has a price, also when some part of the record has none: the note then says that
    /// some tokens have no price, without blaming the model.
    public let unpricedModel: String?

    /// A record of `count` tokens. Without pricing, the record adds no cost and no unpriced
    /// tokens, for providers that do not estimate cost.
    public init(
        date: Date, count: Int64, cost: Decimal? = nil, unpricedTokens: Int64 = 0,
        unpricedModel: String? = nil
    ) {
        self.date = date
        self.count = count
        self.cost = cost
        self.unpricedTokens = max(0, unpricedTokens)
        self.unpricedModel = unpricedModel
    }

    /// Whether this record wins over `other` when both describe the same response.
    ///
    /// One rule applies within a file and across files, so the result never depends on the
    /// read order: the larger count wins, because usage within one response only grows. With
    /// equal counts the earlier date wins, because a copy is written after the original. On a
    /// full tie, pricing decides, so the cost does not depend on the read order either: a
    /// priced record, then the larger cost, then fewer unpriced tokens, then the smaller
    /// unpriced model name (none first).
    public func replaces(_ other: TokenRecord) -> Bool {
        if count != other.count { return count > other.count }
        if date != other.date { return date < other.date }
        switch (cost, other.cost) {
        case (.some, .none): return true
        case (.none, .some): return false
        case (.some(let mine), .some(let theirs)) where mine != theirs: return mine > theirs
        default: break
        }
        if unpricedTokens != other.unpricedTokens { return unpricedTokens < other.unpricedTokens }
        switch (unpricedModel, other.unpricedModel) {
        case (.none, .some): return true
        case (.some(let mine), .some(let theirs)): return mine < theirs
        default: return false
        }
    }

    /// The sum of non-negative counts, or nil when a count is missing or negative, or the sum
    /// does not fit in `Int64`.
    public static func sum(_ counts: [Int64?]) -> Int64? {
        var total: Int64 = 0
        for count in counts {
            guard let count, count >= 0 else { return nil }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
}

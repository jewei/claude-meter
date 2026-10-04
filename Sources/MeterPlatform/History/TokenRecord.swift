import Foundation

/// Tokens that one local record reports, at the time the record was written.
public struct TokenRecord: Hashable, Sendable {
    public let date: Date
    public let count: Int64

    public init(date: Date, count: Int64) {
        self.date = date
        self.count = count
    }

    /// Whether this record wins over `other` when both describe the same response.
    ///
    /// One rule applies within a file and across files, so the result never depends on the
    /// read order: the larger count wins, because usage within one response only grows. With
    /// equal counts the earlier date wins, because a copy is written after the original.
    public func replaces(_ other: TokenRecord) -> Bool {
        count != other.count ? count > other.count : date < other.date
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

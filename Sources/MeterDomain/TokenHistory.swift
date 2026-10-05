import Foundation

/// Token counts per local day for one account.
///
/// History counts tokens, not money or quota. It never affects severity, selection, or quota
/// freshness. A missing day is zero only when the history covers that day; an uncovered
/// period is unknown. The history covers the days from ``coverageStart`` through the day of
/// ``observedAt``, so a history observed on an earlier day cannot answer for any period.
public struct TokenHistory: Hashable, Sendable {
    /// Start of a local day → tokens used on that day.
    public let dailyTokens: [Date: Int64]
    /// The earliest day that the history covers.
    public let coverageStart: Date
    public let observedAt: Date
    /// The time zone used to assign records to days. A change makes the history unknown.
    public let timeZoneID: String
    /// False when the read found no records for the account, which shows as unknown, not
    /// zero. A local read sees only the files modified since ``coverageStart``, so an account
    /// whose records are all older has none either.
    public let hasRecords: Bool
    /// Some records could not be counted, for example because a scan limit was reached.
    public let isPartial: Bool

    public init(
        dailyTokens: [Date: Int64], coverageStart: Date, observedAt: Date,
        timeZoneID: String, hasRecords: Bool = true, isPartial: Bool = false
    ) {
        let valid = dailyTokens.filter { DateBounds.contains($0.key) && $0.value >= 0 }
        self.dailyTokens = valid
        self.coverageStart = coverageStart
        self.observedAt = observedAt
        self.timeZoneID = timeZoneID
        self.hasRecords = hasRecords
        self.isPartial = isPartial || valid.count != dailyTokens.count
    }

    /// A history with no records, for an account that has no local folder.
    public static func empty(
        coverageStart: Date, observedAt: Date, timeZoneID: String
    ) -> TokenHistory {
        TokenHistory(
            dailyTokens: [:], coverageStart: coverageStart, observedAt: observedAt,
            timeZoneID: timeZoneID, hasRecords: false)
    }

    /// Total tokens in `period`, or nil when the history cannot answer for that period.
    ///
    /// The history must be observed after the period ended, or today for a period that
    /// includes today. An older history would count the days after its observation as zero.
    public func tokens(in period: TokenPeriod, now: Date, calendar: Calendar) -> Int64? {
        guard hasRecords, timeZoneID == calendar.timeZone.identifier,
            DateBounds.contains(coverageStart), DateBounds.contains(observedAt),
            let interval = period.interval(at: now, calendar: calendar),
            coverageStart <= interval.start,
            observedAt >= min(interval.end, calendar.startOfDay(for: now))
        else { return nil }
        var total: Int64 = 0
        for (day, count) in dailyTokens where day >= interval.start && day < interval.end {
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }
}

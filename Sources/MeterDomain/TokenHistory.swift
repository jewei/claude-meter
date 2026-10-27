import Foundation

/// Token counts per local day for one account, and an estimate of their cost at API list
/// prices where the provider can price them.
///
/// History counts tokens and estimates money; it never counts quota. It never affects severity, selection, or quota
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
    /// Start of a local day → the estimated cost of its priced tokens, in US dollars.
    public let dailyCost: [Date: Decimal]
    /// Start of a local day → tokens that have no price.
    public let dailyUnpricedTokens: [Date: Int64]
    /// Model names whose tokens have no price, at most ``maximumUnpricedModels``.
    public let unpricedModels: Set<String>

    public static let maximumUnpricedModels = 20

    public init(
        dailyTokens: [Date: Int64], coverageStart: Date, observedAt: Date,
        timeZoneID: String, hasRecords: Bool = true, isPartial: Bool = false,
        dailyCost: [Date: Decimal] = [:], dailyUnpricedTokens: [Date: Int64] = [:],
        unpricedModels: Set<String> = []
    ) {
        let valid = dailyTokens.filter { DateBounds.contains($0.key) && $0.value >= 0 }
        self.dailyCost = dailyCost.filter { DateBounds.contains($0.key) && $0.value >= 0 }
        self.dailyUnpricedTokens = dailyUnpricedTokens.filter {
            DateBounds.contains($0.key) && $0.value >= 0
        }
        self.unpricedModels = Set(unpricedModels.sorted().prefix(Self.maximumUnpricedModels))
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
        guard let interval = answerable(period, now: now, calendar: calendar) else { return nil }
        return Self.sum(dailyTokens, in: interval)
    }

    /// The estimated cost of `period`, with the coverage rules of ``tokens(in:now:calendar:)``.
    /// Nil when the history cannot answer, or when no token of the period has a price (an
    /// amount of zero).
    public func cost(in period: TokenPeriod, now: Date, calendar: Calendar) -> CostEstimate? {
        guard let interval = answerable(period, now: now, calendar: calendar) else { return nil }
        var amount = Decimal(0)
        for (day, cost) in dailyCost where day >= interval.start && day < interval.end {
            amount += cost
        }
        guard amount > 0, let unpriced = Self.sum(dailyUnpricedTokens, in: interval) else {
            return nil
        }
        return CostEstimate(amount: amount, isComplete: unpriced == 0 && !isPartial)
    }

    /// Tokens of `period` without a price, or nil when the history cannot answer.
    public func unpricedTokens(in period: TokenPeriod, now: Date, calendar: Calendar) -> Int64? {
        guard let interval = answerable(period, now: now, calendar: calendar) else { return nil }
        return Self.sum(dailyUnpricedTokens, in: interval)
    }

    /// The interval of `period`, when the history covers it (see ``tokens(in:now:calendar:)``).
    private func answerable(
        _ period: TokenPeriod, now: Date, calendar: Calendar
    ) -> DateInterval? {
        guard hasRecords, timeZoneID == calendar.timeZone.identifier,
            DateBounds.contains(coverageStart), DateBounds.contains(observedAt),
            let interval = period.interval(at: now, calendar: calendar),
            coverageStart <= interval.start,
            observedAt >= min(interval.end, calendar.startOfDay(for: now))
        else { return nil }
        return interval
    }

    /// The sum of the days in `interval`, or nil when it does not fit in `Int64`.
    private static func sum(_ days: [Date: Int64], in interval: DateInterval) -> Int64? {
        var total: Int64 = 0
        for (day, count) in days where day >= interval.start && day < interval.end {
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }
}

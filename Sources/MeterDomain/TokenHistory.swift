import Foundation

/// A calendar period for token totals.
public enum TokenPeriod: CaseIterable, Sendable {
    case today
    case yesterday
    /// Today and the previous six local calendar days.
    case lastSevenDays

    public var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastSevenDays: "Last 7 Days"
        }
    }

    /// The local-day interval that contains the period at `now`.
    public func interval(at now: Date, calendar: Calendar) -> DateInterval? {
        guard DateBounds.contains(now) else { return nil }
        let today = calendar.startOfDay(for: now)
        let (startOffset, endOffset) =
            switch self {
            case .today: (0, 1)
            case .yesterday: (-1, 0)
            case .lastSevenDays: (-6, 1)
            }
        guard let start = calendar.date(byAdding: .day, value: startOffset, to: today),
            let end = calendar.date(byAdding: .day, value: endOffset, to: today),
            DateBounds.contains(start), DateBounds.contains(end)
        else { return nil }
        return DateInterval(start: start, end: end)
    }
}

/// Token counts per local day for one account.
///
/// History counts tokens, not money or quota. It never affects severity, selection, or quota
/// freshness. A missing day is zero only when the history covers that day; an uncovered
/// period is unknown.
public struct TokenHistory: Hashable, Sendable {
    /// Start of a local day → tokens used on that day.
    public let dailyTokens: [Date: Int64]
    /// The earliest day that the history covers.
    public let coverageStart: Date
    public let observedAt: Date
    /// The time zone used to assign records to days. A change makes the history unknown.
    public let timeZoneID: String
    /// False when the source has no records at all, which shows as unknown, not zero.
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
    public func tokens(in period: TokenPeriod, now: Date, calendar: Calendar) -> Int64? {
        guard hasRecords, timeZoneID == calendar.timeZone.identifier,
            DateBounds.contains(coverageStart), DateBounds.contains(observedAt),
            let interval = period.interval(at: now, calendar: calendar),
            coverageStart <= interval.start, observedAt >= interval.start
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

/// Token history for every account of one provider.
public struct ProviderTokenHistory: Hashable, Sendable {
    public enum Source: Sendable {
        /// Local session records on this Mac, counted per account folder.
        case thisMac
        /// Usage that the provider reports for the account.
        case account
    }

    public let provider: ProviderID
    public let source: Source
    public let accounts: [AccountID: TokenHistory]
    public let observedAt: Date
    public let timeZoneID: String
    public let coverageStart: Date

    public init(
        provider: ProviderID, source: Source, accounts: [AccountID: TokenHistory],
        coverageStart: Date, observedAt: Date, timeZoneID: String
    ) {
        self.provider = provider
        self.source = source
        self.accounts = accounts
        self.coverageStart = coverageStart
        self.observedAt = observedAt
        self.timeZoneID = timeZoneID
    }

    /// The history for one card. An account without records reads as unknown, never zero.
    public func history(for account: AccountID) -> TokenHistory {
        accounts[account]
            ?? .empty(coverageStart: coverageStart, observedAt: observedAt, timeZoneID: timeZoneID)
    }
}

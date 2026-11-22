import Foundation
import MeterDomain

/// Adds token records to local calendar days for today and the previous six days.
public struct TokenDayTally: Sendable {
    public let now: Date
    public let calendar: Calendar
    /// The start of the earliest covered day. Older records are ignored.
    public let start: Date
    public private(set) var dailyTokens: [Date: Int64] = [:]
    public private(set) var dailyCost: [Date: Decimal] = [:]
    public private(set) var dailyUnpricedTokens: [Date: Int64] = [:]
    public private(set) var unpricedModels: Set<String> = []
    /// True when some records could not be counted.
    public var isPartial = false
    /// True when the source has records, even if none fall inside the covered days.
    public var hasRecords = false
    /// Precomputed local day intervals `[start, nextDayStart)` covering `[start, now]`, so
    /// ``add(_:)`` never calls `Calendar.startOfDay(for:)` in its inner loop.
    private let dayBounds: [(start: Date, end: Date)]
    private var lastDayIndex = 0

    /// Throws ``HistoryError/invalidDate`` when `now` cannot be placed in a calendar day.
    ///
    /// The tally keeps the time zone that `calendar` has now, so a time zone change during a
    /// read cannot mix days of two zones. Pass `Calendar.autoupdatingCurrent` to follow the
    /// system on the next read.
    public init(now: Date, calendar: Calendar) throws(HistoryError) {
        var fixed = Calendar(identifier: calendar.identifier)
        fixed.timeZone = calendar.timeZone
        guard let interval = TokenPeriod.lastSevenDays.interval(at: now, calendar: fixed) else {
            throw .invalidDate
        }
        self.now = now
        self.calendar = fixed
        self.start = interval.start
        var bounds: [(start: Date, end: Date)] = []
        var dayStart = interval.start
        for _ in 0..<8 where dayStart <= now {
            guard let nextDay = fixed.date(byAdding: .day, value: 1, to: dayStart) else { break }
            bounds.append((start: dayStart, end: nextDay))
            dayStart = nextDay
        }
        self.dayBounds = bounds
        self.lastDayIndex = max(0, bounds.count - 1)
    }

    /// How long after `now` a record can be dated and still be a line that a tool wrote while
    /// the read ran.
    ///
    /// `now` is taken before the scan, and an active session appends lines during it. One
    /// history read lasts at most 20 s (the app's limit), and it can first wait for an earlier
    /// scan to end, so 60 s keeps a margin over that. A later date comes from a wrong clock or a
    /// parse error.
    public static let writeTolerance: TimeInterval = 60

    /// Adds `record` to its local day.
    ///
    /// A record dated after `now`, by at most ``writeTolerance``, is not counted yet and does
    /// not make the tally partial: the next read counts it. A record dated later than that is
    /// not counted and makes the tally partial.
    public mutating func add(_ record: TokenRecord) {
        guard record.date >= start else { return }
        guard record.date <= now else {
            if record.date > now.addingTimeInterval(Self.writeTolerance) { isPartial = true }
            return
        }
        let day = dayStart(for: record.date)
        // Both sums are checked before either changes, so tokens and unpriced tokens agree.
        let (total, totalOverflow) = dailyTokens[day, default: 0].addingReportingOverflow(
            record.count)
        let (unpriced, unpricedOverflow) = dailyUnpricedTokens[day, default: 0]
            .addingReportingOverflow(record.unpricedTokens)
        guard !totalOverflow, !unpricedOverflow else {
            isPartial = true
            return
        }
        dailyTokens[day] = total
        // A record can have a priced part and an unpriced part, so both add independently.
        if let cost = record.cost { dailyCost[day, default: 0] += cost }
        if record.unpricedTokens > 0 {
            dailyUnpricedTokens[day] = unpriced
            if let model = record.unpricedModel,
                unpricedModels.count < TokenHistory.maximumUnpricedModels
            {
                unpricedModels.insert(model)
            }
        }
    }

    private mutating func dayStart(for date: Date) -> Date {
        if !dayBounds.isEmpty {
            let cached = dayBounds[lastDayIndex]
            if date >= cached.start, date < cached.end { return cached.start }
            for index in dayBounds.indices.reversed() {
                let bound = dayBounds[index]
                if date >= bound.start, date < bound.end {
                    lastDayIndex = index
                    return bound.start
                }
            }
        }
        return calendar.startOfDay(for: date)
    }

    /// The counted days as history.
    public var history: TokenHistory {
        TokenHistory(
            dailyTokens: dailyTokens, coverageStart: start, observedAt: now,
            timeZoneID: calendar.timeZone.identifier, hasRecords: hasRecords,
            isPartial: isPartial, dailyCost: dailyCost, dailyUnpricedTokens: dailyUnpricedTokens,
            unpricedModels: unpricedModels)
    }
}

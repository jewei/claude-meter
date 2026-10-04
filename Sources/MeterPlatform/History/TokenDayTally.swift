import Foundation
import MeterDomain

/// Adds token records to local calendar days for today and the previous six days.
public struct TokenDayTally: Sendable {
    public let now: Date
    public let calendar: Calendar
    /// The start of the earliest covered day. Older records are ignored.
    public let start: Date
    public private(set) var dailyTokens: [Date: Int64] = [:]
    /// True when some records could not be counted.
    public var isPartial = false
    /// True when the source has records, even if none fall inside the covered days.
    public var hasRecords = false

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
    }

    /// Adds `record` to its local day. A record dated after `now` is not counted and makes the
    /// tally partial, because a clock or parse error produced it.
    public mutating func add(_ record: TokenRecord) {
        guard record.date >= start else { return }
        guard record.date <= now else {
            isPartial = true
            return
        }
        let day = calendar.startOfDay(for: record.date)
        guard let total = TokenRecord.sum([dailyTokens[day, default: 0], record.count]) else {
            isPartial = true
            return
        }
        dailyTokens[day] = total
    }

    /// The counted days as history.
    public var history: TokenHistory {
        TokenHistory(
            dailyTokens: dailyTokens, coverageStart: start, observedAt: now,
            timeZoneID: calendar.timeZone.identifier, hasRecords: hasRecords,
            isPartial: isPartial)
    }
}

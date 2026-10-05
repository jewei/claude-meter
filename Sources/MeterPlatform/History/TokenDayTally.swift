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

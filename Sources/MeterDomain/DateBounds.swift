import Foundation

/// The range of dates that the app accepts from providers and from disk.
///
/// External input can hold any number. Foundation traps when it formats some huge dates, and a
/// date before 1970 or after 3000 is always a parsing mistake, so values outside this range are
/// treated as unknown.
public enum DateBounds {
    public static let earliest = Date(timeIntervalSince1970: 0)
    /// 3000-01-01T00:00:00Z.
    public static let latest = Date(timeIntervalSince1970: 32_503_680_000)

    public static func contains(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && date >= earliest && date < latest
    }

    /// The date if it is inside the bounds, otherwise nil.
    public static func validated(_ date: Date?) -> Date? {
        guard let date, contains(date) else { return nil }
        return date
    }

    /// A Unix timestamp in seconds, if it is inside the bounds.
    public static func date(secondsSince1970 seconds: Double) -> Date? {
        guard seconds.isFinite else { return nil }
        return validated(Date(timeIntervalSince1970: seconds))
    }
}

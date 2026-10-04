import Foundation

/// Compact text for the time until a provider-reported date.
///
/// All reset and refill text uses this one format, never a calendar date or weekday, because
/// rolling windows are about duration.
public enum Countdown {
    /// `42m`, `3h 12m`, `36h`, or `6d 7h`. Nil when `date` is not in the future.
    ///
    /// Minutes round to the nearest minute, with a minimum of one. Below 12 hours the text
    /// shows hours and minutes; below 48 hours, whole hours; from 48 hours, days and hours.
    /// Hours always round down, so the text never claims more time than remains.
    public static func text(until date: Date, now: Date) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds.isFinite, seconds > 0,
            let rounded = Int(exactly: (seconds / 60).rounded())
        else { return nil }
        let minutes = max(1, rounded)
        let hours = minutes / 60
        switch hours {
        case 0:
            return "\(minutes)m"
        case ..<12:
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        case ..<48:
            return "\(hours)h"
        default:
            let days = hours / 24
            let remainder = hours % 24
            return remainder == 0 ? "\(days)d" : "\(days)d \(remainder)h"
        }
    }

    /// `in 3h 12m`, or nil when `date` is not in the future.
    public static func phrase(until date: Date, now: Date) -> String? {
        text(until: date, now: now).map { "in \($0)" }
    }
}

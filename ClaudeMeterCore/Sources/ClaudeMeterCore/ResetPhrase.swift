import Foundation

/// The app-wide rule for describing when a rolling window resets, relative to now:
/// after rounding to the nearest minute: under an hour → minutes ("42m"),
/// under 48 hours → hours ("3h 20m", "36h"),
/// otherwise → days and remaining whole hours ("6d 7h"). Never a calendar date or weekday — "20 Jul"
/// makes the reader do the math, and a bare weekday is ambiguous a week out.
public enum ResetPhrase {
    /// "42m" | "3h 20m" | "36h" | "6d 7h" — nil once the reset has passed.
    public static func duration(until reset: Date, asOf now: Date) -> String? {
        switch parts(until: reset, asOf: now) {
        case .none: return nil
        case .minutes(let m): return "\(m)m"
        case .hoursMinutes(let h, let m): return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        case .hours(let h): return "\(h)h"
        case .daysHours(let d, let h): return h > 0 ? "\(d)d \(h)h" : "\(d)d"
        }
    }

    /// "in 42m" | "in 36h" | "in 6d 7h" — reads naturally after "resets"/"refills".
    public static func spoken(until reset: Date, asOf now: Date) -> String? {
        duration(until: reset, asOf: now).map { "in \($0)" }
    }

    /// "42m" | "36h" | "6d 7h" — for tight spaces (widget rows).
    public static func compact(until reset: Date, asOf now: Date) -> String? {
        switch parts(until: reset, asOf: now) {
        case .none: return nil
        case .minutes(let m): return "\(m)m"
        case .hoursMinutes(let h, _), .hours(let h): return "\(h)h"
        case .daysHours(let d, let h): return h > 0 ? "\(d)d \(h)h" : "\(d)d"
        }
    }

    private enum Parts {
        case none
        case minutes(Int)
        /// Below 12 h the minute detail still matters ("3h 20m").
        case hoursMinutes(Int, Int)
        case hours(Int)
        case daysHours(Int, Int)
    }

    private static func parts(until reset: Date, asOf now: Date) -> Parts {
        let interval = reset.timeIntervalSince(now)
        guard interval.isFinite, interval > 0,
            let roundedMinutes = Int(exactly: (interval / 60).rounded())
        else { return .none }
        let totalMinutes = max(1, roundedMinutes)
        if totalMinutes < 60 { return .minutes(totalMinutes) }
        if totalMinutes < 48 * 60 {
            let hours = totalMinutes / 60
            if hours < 12 { return .hoursMinutes(hours, totalMinutes % 60) }
            return .hours(Int((Double(totalMinutes) / 60).rounded()))
        }
        let totalHours = totalMinutes / 60
        return .daysHours(totalHours / 24, totalHours % 24)
    }
}

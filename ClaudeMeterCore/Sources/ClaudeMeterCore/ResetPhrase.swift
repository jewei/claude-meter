import Foundation

/// The app-wide rule for describing when a rolling window resets, relative to now:
/// under an hour → minutes ("42m"), under 48 hours → hours ("3h 20m", "36h"),
/// otherwise → whole days ("4 days"). Never a calendar date or weekday — "20 Jul"
/// makes the reader do the math, and a bare weekday is ambiguous a week out.
public enum ResetPhrase {
    /// "42m" | "3h 20m" | "36h" | "4 days" — nil once the reset has passed.
    public static func duration(until reset: Date, asOf now: Date) -> String? {
        switch parts(until: reset, asOf: now) {
        case .none: return nil
        case .minutes(let m): return "\(m)m"
        case .hoursMinutes(let h, let m): return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        case .hours(let h): return "\(h)h"
        case .days(let d): return "\(d) days"
        }
    }

    /// "in 42m" | "in 36h" | "in 4 days" — reads naturally after "resets"/"refills".
    public static func spoken(until reset: Date, asOf now: Date) -> String? {
        duration(until: reset, asOf: now).map { "in \($0)" }
    }

    /// "42m" | "36h" | "4d" — for tight spaces (widget rows).
    public static func compact(until reset: Date, asOf now: Date) -> String? {
        switch parts(until: reset, asOf: now) {
        case .none: return nil
        case .minutes(let m): return "\(m)m"
        case .hoursMinutes(let h, _), .hours(let h): return "\(h)h"
        case .days(let d): return "\(d)d"
        }
    }

    private enum Parts {
        case none
        case minutes(Int)
        /// Below 12 h the minute detail still matters ("3h 20m").
        case hoursMinutes(Int, Int)
        case hours(Int)
        case days(Int)
    }

    private static func parts(until reset: Date, asOf now: Date) -> Parts {
        let interval = reset.timeIntervalSince(now)
        guard interval > 0 else { return .none }
        if interval < 3600 { return .minutes(max(1, Int((interval / 60).rounded()))) }
        if interval < 48 * 3600 {
            let totalMinutes = Int((interval / 60).rounded())
            let hours = totalMinutes / 60
            if hours < 12 { return .hoursMinutes(hours, totalMinutes % 60) }
            return .hours(Int((interval / 3600).rounded()))
        }
        return .days(max(2, Int((interval / 86400).rounded())))
    }
}

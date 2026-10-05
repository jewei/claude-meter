import Foundation

/// Parses the HTTP `Retry-After` header.
public enum RetryAfter {
    /// The longest delay that ``delay(_:now:)`` returns: 366 days. A larger value is clamped,
    /// so a broken proxy cannot make a caller overflow a `Duration` or a `Date`.
    public static let maximum: TimeInterval = 366 * 86_400

    /// Seconds to wait after `now`, at most ``maximum``, or nil when the value is missing,
    /// invalid, or not in the future. Accepts delta-seconds (ASCII digits only, any length)
    /// and IMF-fixdate HTTP dates.
    public static func delay(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) {
            // Too many digits parse as infinity, which still means "later than the maximum".
            guard let seconds = TimeInterval(value), seconds > 0 else { return nil }
            return min(seconds, maximum)
        }
        guard let date = httpDate(value) else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return min(seconds, maximum)
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

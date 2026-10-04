import Foundation

/// Parses the HTTP `Retry-After` header.
public enum RetryAfter {
    /// Seconds to wait after `now`, or nil when the value is missing, invalid, or not in the
    /// future. Accepts delta-seconds (ASCII digits only) and IMF-fixdate HTTP dates.
    public static func delay(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let seconds = TimeInterval(value), seconds > 0, seconds.isFinite else {
                return nil
            }
            return seconds
        }
        guard let date = httpDate(value) else { return nil }
        let seconds = date.timeIntervalSince(now)
        return seconds > 0 ? seconds : nil
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

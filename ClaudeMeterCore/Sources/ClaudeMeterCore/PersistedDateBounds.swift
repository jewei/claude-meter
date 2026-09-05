import Foundation

/// The date interval that Claude Meter accepts from providers and writes to its
/// durable JSON files. Foundation's ISO-8601 formatter can trap for very large,
/// finite `Date` values, so persistence must validate before it formats a date.
public enum PersistedDateBounds {
    public static let minimumEpoch: TimeInterval = 0
    public static let maximumEpoch: TimeInterval = 32_503_680_000  // 3000-01-01T00:00:00Z

    public static func contains(_ date: Date) -> Bool {
        contains(timeIntervalSince1970: date.timeIntervalSince1970)
    }

    public static func contains(timeIntervalSince1970 seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= minimumEpoch && seconds < maximumEpoch
    }

    public static func date(timeIntervalSince1970 seconds: TimeInterval) -> Date? {
        guard contains(timeIntervalSince1970: seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

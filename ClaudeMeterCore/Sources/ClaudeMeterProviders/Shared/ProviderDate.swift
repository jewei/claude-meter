import ClaudeMeterCore
import Foundation

/// Shared timestamp parsing for provider quota, reset, and credential data.
enum ProviderDate {
    // These formatters are never mutated after creation.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private final class ReadOnlyDateFormatters {
        let values: [DateFormatter]

        init(_ formats: [String]) {
            values = formats.map { format in
                let formatter = DateFormatter()
                formatter.dateFormat = format
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                return formatter
            }
        }
    }

    private nonisolated(unsafe) static let legacyTimestampFormatters = ReadOnlyDateFormatters([
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
    ])
    static func parseISO8601(_ str: String) -> Date? {
        if let date = isoFractional.date(from: str) { return date }
        if let date = isoPlain.date(from: str) { return date }
        for f in legacyTimestampFormatters.values {
            if let date = f.date(from: str) { return date }
        }
        return nil
    }

}

/// Parses a timestamp that may be epoch seconds/milliseconds or ISO-8601
/// (with or without fractional seconds). Returns nil for empty/unparseable input.
func parseEpochOrISODate(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    if let number = Double(string), number.isFinite {
        // Heuristic: 13-digit values are milliseconds.
        let seconds = abs(number) > 1_000_000_000_000 ? number / 1000 : number
        return boundedProviderDate(timeIntervalSince1970: seconds)
    }
    guard let date = ProviderDate.parseISO8601(string) else { return nil }
    return boundedProviderDate(timeIntervalSince1970: date.timeIntervalSince1970)
}

/// Converts an external provider epoch without creating dates that Foundation's
/// ISO-8601 encoder cannot safely represent. These services did not exist before
/// 1970, and no usage or credential timestamp near year 3000 is plausible.
func boundedProviderDate(timeIntervalSince1970 seconds: TimeInterval) -> Date? {
    PersistedDateBounds.date(timeIntervalSince1970: seconds)
}

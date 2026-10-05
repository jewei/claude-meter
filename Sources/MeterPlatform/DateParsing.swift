import Foundation
import MeterDomain

/// Parses provider timestamps into dates inside ``DateBounds``.
public enum DateParsing {
    /// ISO-8601 with or without fractional seconds of any length, and with `Z` or an offset.
    /// A time without a zone is rejected: it could be local time, and a guess would move
    /// records to another day.
    public static func iso8601(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let date = try? Date(trimmed, strategy: .iso8601) {
            return DateBounds.validated(date)
        }
        // Some Foundation versions accept only a fixed fraction length. Normalize to
        // milliseconds and try again.
        guard let match = trimmed.wholeMatch(of: /(.+T[0-9:]+)\.([0-9]+)(Z|[+-][0-9:]+)/) else {
            return nil
        }
        let fraction = String(match.2.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        let normalized = "\(match.1).\(fraction)\(match.3)"
        let strategy = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return DateBounds.validated(try? Date(normalized, strategy: strategy))
    }

    /// A Unix timestamp in seconds, or in milliseconds when the value is too large for seconds.
    public static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        return DateBounds.date(secondsSince1970: seconds)
    }

    /// A JSON value that holds an ISO-8601 string, an epoch number, or an epoch string.
    public static func date(_ value: JSONValue?) -> Date? {
        switch value {
        case .number(let number):
            return epoch(number)
        case .string(let string):
            return iso8601(string) ?? NumericText.double(string).flatMap(epoch)
        default:
            return nil
        }
    }
}

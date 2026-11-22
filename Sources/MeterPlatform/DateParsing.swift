import Foundation
import MeterDomain

/// Parses provider timestamps into dates inside ``DateBounds``.
public enum DateParsing {
    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// ISO-8601 with or without fractional seconds of any length, and with `Z` or an offset.
    /// A time without a zone is rejected: it could be local time, and a guess would move
    /// records to another day.
    public static func iso8601(_ text: String) -> Date? {
        if let fast = parseRFC3339Fast(text) {
            return DateBounds.validated(fast)
        }
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
        return DateBounds.validated(try? Date(normalized, strategy: Self.fractionalISO8601))
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

    /// Zero-allocation ASCII fast path for standard RFC 3339 timestamps:
    /// `YYYY-MM-DD[T|t]HH:MM:SS(.frac...)?(Z|z|[+-]HH:?MM)` with optional outer ASCII spaces.
    /// Handles arbitrary fractional-second precision in a single pass without throwing.
    private static func parseRFC3339Fast(_ text: String) -> Date? {
        var bytes = text.utf8[...]
        while let first = bytes.first, first == 0x20 || first == 0x09 {
            bytes = bytes.dropFirst()
        }
        while let last = bytes.last, last == 0x20 || last == 0x09 {
            bytes = bytes.dropLast()
        }
        // Minimum length: `YYYY-MM-DDTHH:MM:SSZ` (20 bytes).
        guard bytes.count >= 20 else { return nil }
        var index = bytes.startIndex

        func nextByte() -> UInt8? {
            guard index < bytes.endIndex else { return nil }
            defer { index = bytes.index(after: index) }
            return bytes[index]
        }

        func readDigits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let byte = nextByte(), byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }

        guard let year = readDigits(4), nextByte() == 0x2D,
            let month = readDigits(2), nextByte() == 0x2D,
            let day = readDigits(2),
            let separator = nextByte(), separator == 0x54 || separator == 0x74,
            let hour = readDigits(2), nextByte() == 0x3A,
            let minute = readDigits(2), nextByte() == 0x3A,
            let second = readDigits(2)
        else { return nil }

        guard (1...12).contains(month),
            (1...daysInMonth(year: year, month: month)).contains(day),
            (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { return nil }

        var fractionalSeconds = 0.0
        if index < bytes.endIndex, bytes[index] == 0x2E {
            index = bytes.index(after: index)
            var digits = 0
            var scale = 0.1
            while index < bytes.endIndex {
                let byte = bytes[index]
                guard byte >= 0x30, byte <= 0x39 else { break }
                if digits < 9 {
                    fractionalSeconds += Double(byte - 0x30) * scale
                    scale *= 0.1
                }
                digits += 1
                index = bytes.index(after: index)
            }
            guard digits > 0 else { return nil }
        }

        guard let zone = nextByte() else { return nil }
        let offsetSeconds: Int
        if zone == 0x5A || zone == 0x7A {
            offsetSeconds = 0
        } else if zone == 0x2B || zone == 0x2D {
            let sign = zone == 0x2B ? 1 : -1
            guard let tzHour = readDigits(2), (0...23).contains(tzHour) else { return nil }
            let tzMinute: Int
            if index < bytes.endIndex {
                if bytes[index] == 0x3A { index = bytes.index(after: index) }
                guard let m = readDigits(2), (0...59).contains(m) else { return nil }
                tzMinute = m
            } else {
                tzMinute = 0
            }
            offsetSeconds = sign * (tzHour * 3_600 + tzMinute * 60)
        } else {
            return nil
        }
        guard index == bytes.endIndex else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let wholeSeconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(wholeSeconds) + fractionalSeconds)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: isLeapYear(year) ? 29 : 28
        default: 0
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Days since 1970-01-01 (Howard Hinnant's civil-date algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

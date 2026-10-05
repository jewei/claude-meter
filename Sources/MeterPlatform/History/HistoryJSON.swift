import Foundation
import MeterDomain

/// Lenient JSON fields for history lines.
///
/// Decoding one of these fields never throws. A value of an unexpected type decodes as an
/// invalid value, so one odd field cannot hide the rest of its line. A missing or null field
/// decodes as nil through ``Swift/KeyedDecodingContainer/lenient(_:)``.
public enum HistoryJSON {
    /// A token count: a non-negative integer, as a number or as a string of decimal digits.
    /// Booleans, fractions, negative numbers, and values larger than `Int64` are invalid.
    public struct Count: Decodable, Hashable, Sendable {
        /// The count, or nil when the value is present but invalid.
        public let value: Int64?

        /// The count of an optional field: zero when the field is missing or null, and nil when
        /// it is present but invalid.
        public static func orZero(_ field: Count?) -> Int64? {
            guard let field else { return 0 }
            return field.value
        }

        public init(from decoder: any Decoder) {
            guard let container = try? decoder.singleValueContainer() else {
                value = nil
                return
            }
            if let number = try? container.decode(Int64.self) {
                value = number >= 0 ? number : nil
            } else if let text = try? container.decode(String.self), !text.isEmpty,
                text.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })
            {
                value = Int64(text)
            } else {
                value = nil
            }
        }
    }

    /// An identifier: a non-empty string of at most ``maxBytes`` UTF-8 bytes.
    public struct Text: Decodable, Hashable, Sendable {
        public static let maxBytes = 512

        /// The text, or nil when the value is present but not a usable identifier.
        public let value: String?

        public init(from decoder: any Decoder) {
            let text = try? decoder.singleValueContainer().decode(String.self)
            if let text, !text.isEmpty, text.utf8.count <= Self.maxBytes {
                value = text
            } else {
                value = nil
            }
        }
    }

    /// A date: an ISO-8601 string, or Unix time in seconds or milliseconds as a number or a
    /// string. See ``DateParsing/epoch(_:)`` for how milliseconds are detected.
    public struct Timestamp: Decodable, Hashable, Sendable {
        /// The date, or nil when the value is present but not a date inside ``DateBounds``.
        public let date: Date?

        public init(from decoder: any Decoder) {
            guard let container = try? decoder.singleValueContainer() else {
                date = nil
                return
            }
            if let number = try? container.decode(Double.self) {
                date = DateParsing.epoch(number)
            } else if let text = try? container.decode(String.self) {
                date = DateParsing.date(.string(text))
            } else {
                date = nil
            }
        }
    }

    /// A finite number, as a JSON number or a string of decimal text. Booleans are invalid.
    public struct Number: Decodable, Hashable, Sendable {
        /// The number, or nil when the value is present but not a number.
        public let value: Double?

        public init(from decoder: any Decoder) {
            guard let container = try? decoder.singleValueContainer() else {
                value = nil
                return
            }
            if let number = try? container.decode(Double.self), number.isFinite {
                value = number
            } else if let text = try? container.decode(String.self) {
                value = NumericText.double(text)
            } else {
                value = nil
            }
        }
    }
}

extension KeyedDecodingContainer {
    /// The value at `key`, or nil when the key is missing or null, or the value has another
    /// shape than `Value` expects.
    public func lenient<Value: Decodable>(_ key: Key) -> Value? {
        (try? decodeIfPresent(Value.self, forKey: key)) ?? nil
    }
}

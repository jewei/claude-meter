import Foundation

/// Any JSON value. Use it to read loosely typed provider data without `Any`.
public enum JSONValue: Hashable, Sendable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    /// A number, or a string that holds a decimal number. Protobuf JSON sends 64-bit integers
    /// as strings.
    public var doubleValue: Double? {
        switch self {
        case .number(let number): number
        case .string(let string): NumericText.double(string)
        default: nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let bool) = self else { return nil }
        return bool
    }

    /// Decodes `data` as one JSON value, or nil when it is not JSON.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The fields of an object, or nil for any other value.
    public var objectValue: [String: JSONValue]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    /// Trimmed text that is not empty, or nil.
    public var text: String? {
        guard let trimmed = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// A whole number that fits in `Int`, from a number or a numeric string.
    public var integerValue: Int? {
        guard let number = doubleValue, number.rounded() == number else { return nil }
        return Int(exactly: number)
    }

    /// An exact amount from a number or a numeric string. Text goes straight to `Decimal`, and
    /// a number goes through its shortest text, so `112.4` stays `112.4`.
    public var decimalValue: Decimal? {
        switch self {
        case .number(let number):
            guard number.isFinite else { return nil }
            return Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX"))
        case .string(let text):
            guard NumericText.double(text) != nil else { return nil }
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        default:
            return nil
        }
    }

    /// An amount in US cents, as a number or a numeric string, converted exactly to dollars.
    public var dollarsFromCents: Decimal? {
        decimalValue.map { $0 / 100 }
    }
}

/// Strict decimal parsing for provider text. Rejects hex, exponents written as words, and
/// whitespace, which `Double(_:)` would accept in some forms.
public enum NumericText {
    public static func double(_ text: String) -> Double? {
        let pattern = /^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/
        guard text.wholeMatch(of: pattern) != nil, let value = Double(text), value.isFinite else {
            return nil
        }
        return value
    }
}

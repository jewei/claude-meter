import Foundation
import MeterPlatform

extension JSONValue {
    /// Decodes `data` as one JSON value, or nil when it is not JSON.
    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The fields of an object, or nil for any other value.
    var objectValue: [String: JSONValue]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    /// Trimmed text that is not empty, or nil.
    var text: String? {
        guard let trimmed = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// A whole number that fits in `Int`, from a number or a numeric string.
    var integerValue: Int? {
        guard let number = doubleValue, number.rounded() == number else { return nil }
        return Int(exactly: number)
    }

    /// An amount from a number or a numeric string. Text goes straight to `Decimal`, and a
    /// number goes through its shortest text, so `112.4` stays `112.4`.
    var decimalValue: Decimal? {
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

    /// A number or a numeric string. Nil when the field is absent or null.
    ///
    /// Any other value throws, so a changed wire format cannot pass as "unknown".
    static func strictNumber(_ value: JSONValue?) throws(MalformedValue) -> Double? {
        switch value {
        case nil, .null?:
            return nil
        case .some(let value):
            guard let number = value.doubleValue, number.isFinite else { throw MalformedValue() }
            return number
        }
    }
}

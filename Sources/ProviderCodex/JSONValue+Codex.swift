import Foundation
import MeterPlatform

extension JSONValue {
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

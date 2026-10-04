import Foundation
import MeterDomain

/// Reads the unverified claims of a JSON Web Token.
///
/// Claims are hints, never proof of identity: the app uses them to skip a request with an
/// expired token and to tell logins apart. It never authenticates anyone with them.
public struct JWTClaims: Sendable {
    /// Tokens larger than this are not parsed.
    public static let maxTokenBytes = 64 * 1024

    private let claims: [String: JSONValue]

    /// Nil when the token is not three base64url segments with a JSON object payload.
    public init?(token: String) {
        guard token.utf8.count <= Self.maxTokenBytes else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
            let payload = Base64URL.decode(String(segments[1])),
            case .object(let claims) = try? JSONDecoder().decode(JSONValue.self, from: payload)
        else { return nil }
        self.claims = claims
    }

    /// The `exp` claim, when it is a number inside ``DateBounds``.
    public var expiresAt: Date? {
        guard case .number(let seconds) = claims["exp"] else { return nil }
        return DateBounds.date(secondsSince1970: seconds)
    }

    /// A string claim at a path of object keys, such as `["https://api.openai.com/auth", "user_id"]`.
    public func string(_ path: String...) -> String? {
        string(path)
    }

    public func string(_ path: [String]) -> String? {
        guard let first = path.first else { return nil }
        var value = claims[first]
        for key in path.dropFirst() {
            guard case .object(let object) = value else { return nil }
            value = object[key]
        }
        guard case .string(let string) = value, !string.isEmpty else { return nil }
        return string
    }
}

public enum Base64URL {
    /// Decodes RFC 4648 base64url, with or without padding.
    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

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

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

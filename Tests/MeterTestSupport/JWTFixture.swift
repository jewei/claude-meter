import Foundation

/// Builds unsigned JSON Web Tokens for tests.
public enum JWTFixture {
    /// A token whose payload is `claims` encoded as JSON.
    public static func token(_ claims: [String: Any]) -> String {
        let header = encode(["alg": "none", "typ": "JWT"])
        let payload = encode(claims)
        return "\(header).\(payload).signature"
    }

    /// A token that expires at `date`.
    public static func token(expiresAt date: Date, extra: [String: Any] = [:]) -> String {
        var claims = extra
        claims["exp"] = date.timeIntervalSince1970
        return token(claims)
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

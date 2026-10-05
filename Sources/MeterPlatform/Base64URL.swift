import Foundation

/// Base64url text (RFC 4648, section 5), as in JSON Web Tokens.
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

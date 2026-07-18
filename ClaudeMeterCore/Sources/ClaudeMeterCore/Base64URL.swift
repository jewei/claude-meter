import Foundation

/// RFC 4648 base64url (unpadded) — the one alphabet mapping shared by hook marker
/// route suffixes, Cursor token storage, and notification dedup keys. The bash side
/// of the hook bridge mirrors this with `base64 | tr "/+" "_-" | tr -d "="`.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

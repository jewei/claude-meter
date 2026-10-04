import CryptoKit
import Foundation

public enum Digest {
    /// The lowercase hexadecimal SHA-256 of `text` as UTF-8.
    public static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A digest of several parts that cannot collide by moving text between parts.
    public static func sha256(parts: [String]) -> String {
        sha256(parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|"))
    }
}

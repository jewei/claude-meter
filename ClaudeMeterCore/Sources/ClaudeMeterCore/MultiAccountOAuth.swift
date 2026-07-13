import CryptoKit
import Foundation

/// Per-account OAuth usage: maps each discovered Claude config dir to its own
/// Keychain credential and usage reading. Claude Code (≈2.1.52+) namespaces the
/// Keychain entry per config dir as `Claude Code-credentials-<hash>` where
/// `<hash>` is the first 8 hex chars of SHA-256 of the config dir's absolute
/// path (verified empirically); the default `~/.claude` keeps the legacy
/// unsuffixed service.
public enum MultiAccountOAuth {

    /// First 8 lowercase hex chars of SHA-256 over the path's UTF-8 bytes.
    public static func hashedServiceSuffix(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}

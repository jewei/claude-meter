import Foundation
import MeterDomain
import MeterPlatform

/// The login that Claude Code recorded in a config dir's `.claude.json`, read without network.
struct LocalIdentity: Sendable, Equatable {
    /// Claude Code keeps per-project state in this file too, so it can be large.
    static let maxFileBytes = 4 * 1024 * 1024

    let accountUUID: String?
    let organizationUUID: String?
    /// `organizationRateLimitTier`, else `userRateLimitTier`.
    let rateLimitTier: String?

    /// A stable owner for retention, or nil when the file names no account.
    var owner: AccountOwner? {
        guard let accountUUID, !accountUUID.isEmpty else { return nil }
        return .identity(Digest.sha256(parts: ["claude", accountUUID, organizationUUID ?? ""]))
    }

    /// The identity file of a config dir. For `~/.claude` Claude Code writes `~/.claude.json`
    /// in the home folder, not inside the dir.
    static func file(for directory: URL, home: URL) -> URL {
        let defaultDirectory = home.appending(path: ".claude", directoryHint: .isDirectory)
        if directory.standardizedFileURL.path == defaultDirectory.standardizedFileURL.path {
            return home.appending(path: ".claude.json")
        }
        return directory.appending(path: ".claude.json")
    }

    /// Reads the file. Blocking: call through ``BlockingIO``. Nil when the file is missing,
    /// unreadable, or has no `oauthAccount` object.
    static func read(_ file: URL) -> LocalIdentity? {
        guard let data = try? LocalFile.read(file, maxBytes: maxFileBytes) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> LocalIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        return LocalIdentity(
            accountUUID: account["accountUuid"] as? String,
            organizationUUID: account["organizationUuid"] as? String,
            rateLimitTier: account["organizationRateLimitTier"] as? String
                ?? account["userRateLimitTier"] as? String)
    }
}

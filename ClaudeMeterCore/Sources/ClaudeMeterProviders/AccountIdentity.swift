import ClaudeMeterCore
import Foundation

/// Identity bound inside a Claude config dir, read from local metadata only —
/// no network, no subprocess. Claude Code writes `oauthAccount` (email, org,
/// tier) into `<configDir>/.claude.json`; for the DEFAULT dir the file lives at
/// the home root (`~/.claude.json`), not inside `~/.claude/`.
public struct ClaudeAccountIdentity: Sendable, Equatable {
    public let email: String?
    public let organizationUuid: String?
    public let organizationName: String?
    public let displayName: String?
    public let rateLimitTier: String?

    public init(
        email: String?, organizationUuid: String?, organizationName: String?,
        displayName: String?, rateLimitTier: String?
    ) {
        self.email = email
        self.organizationUuid = organizationUuid
        self.organizationName = organizationName
        self.displayName = displayName
        self.rateLimitTier = rateLimitTier
    }
}

public enum AccountIdentityReader {

    /// Where the identity metadata lives for a config dir (see type doc).
    public static func identityFilePath(configDir: URL, home: URL) -> URL {
        let isDefault =
            configDir.standardizedFileURL.path
            == home.appendingPathComponent(".claude").standardizedFileURL.path
        return isDefault
            ? home.appendingPathComponent(".claude.json")
            : configDir.appendingPathComponent(".claude.json")
    }

    public static func loadLocal(
        configDir: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClaudeAccountIdentity? {
        let url = identityFilePath(configDir: configDir, home: home)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// `nil` when the file has no `oauthAccount` (not logged in) or isn't JSON.
    static func parse(_ data: Data) -> ClaudeAccountIdentity? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = obj["oauthAccount"] as? [String: Any]
        else { return nil }
        return ClaudeAccountIdentity(
            email: oauth["emailAddress"] as? String,
            organizationUuid: oauth["organizationUuid"] as? String,
            organizationName: oauth["organizationName"] as? String,
            displayName: oauth["displayName"] as? String,
            rateLimitTier: (oauth["organizationRateLimitTier"] as? String)
                ?? (oauth["userRateLimitTier"] as? String)
        )
    }
}

import Foundation
import MeterDomain
import MeterPlatform

/// One login to read in automatic mode: a config dir, or Claude Code's active login when no
/// config dir matches its Keychain item.
struct LoginSlot: Sendable, Equatable {
    /// The key prefix of an active login that matches no config dir.
    static let unmappedPrefix = "oauth-"

    let id: AccountID
    let name: String
    /// Keychain services to try, preferred first.
    let services: [String]
    /// The `.claude.json` that names the login, when the slot has a config dir.
    let identityFile: URL?
    /// A folder problem. Such a slot is listed but never read.
    let issue: UsageIssue?
    /// Who reads failure texts while the slot is not the active login.
    let audience: AccountFailure.Audience

    init(account: ClaudeAccount, home: URL) {
        id = account.id
        name = account.name
        services = ClaudeCodeKeychain.services(for: account)
        identityFile = LocalIdentity.file(for: account.directory, home: home)
        issue = account.issue
        audience = .configDirectory(
            ConfigDirectoryScanner.displayPath(account.directory, home: home))
    }

    /// The active login of a Keychain item that matches no config dir. It keeps its own key,
    /// `oauth-<first 8 hex of SHA-256 of the service>`, and never takes the default account.
    init(unmappedService service: String) {
        id = AccountID(Self.unmappedPrefix + ClaudeCodeKeychain.shortHash(service))
        name = id.rawValue
        services = [service]
        identityFile = nil
        issue = nil
        audience = .activeLogin
    }

    /// The legacy item when `~/.claude` does not exist. It keeps the default account key and
    /// the default identity file, `~/.claude.json`, which Claude Code writes in the home folder.
    static func legacyDefault(home: URL) -> LoginSlot {
        LoginSlot(
            id: ClaudeAccount.defaultID,
            name: ConfigDirectoryScanner.name(for: ClaudeAccount.defaultID),
            services: [ClaudeCodeKeychain.legacyService],
            identityFile: home.appending(path: ".claude.json"))
    }

    private init(id: AccountID, name: String, services: [String], identityFile: URL?) {
        self.id = id
        self.name = name
        self.services = services
        self.identityFile = identityFile
        self.issue = nil
        self.audience = .activeLogin
    }
}

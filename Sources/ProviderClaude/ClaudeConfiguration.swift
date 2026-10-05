import Foundation
import MeterDomain

/// The user's Claude settings. The provider reads a fresh value at the start of each refresh.
public struct ClaudeConfiguration: Sendable, Equatable {
    /// How Claude Meter gets a Claude login.
    public enum Connection: String, Codable, Sendable, CaseIterable {
        /// Not connected. A refresh fails and asks the user to connect.
        case off
        /// Read Claude Code's own Keychain credentials, one login per config dir. Read-only.
        case automatic
        /// Use tokens that the user entered. The app owns and refreshes this one credential.
        case manual
    }

    /// How the provider gets a login: off, Claude Code's credentials, or tokens the user
    /// entered.
    public var connection: Connection
    /// Config dirs that the user added in Settings, in addition to the `~/.claude*` scan.
    public var extraDirectories: [URL]
    /// Account keys that the user turned off. The default account `claude` is never disabled,
    /// even when this set contains it.
    public var disabledAccounts: Set<AccountID>

    /// Removes the default account from `disabledAccounts`.
    public init(
        connection: Connection = .off,
        extraDirectories: [URL] = [],
        disabledAccounts: Set<AccountID> = []
    ) {
        self.connection = connection
        self.extraDirectories = extraDirectories
        self.disabledAccounts = disabledAccounts.subtracting([ClaudeAccount.defaultID])
    }

    /// Whether the account with `id` is turned on. The default account always is.
    public func isEnabled(_ id: AccountID) -> Bool {
        id == ClaudeAccount.defaultID || !disabledAccounts.contains(id)
    }
}

import Foundation
import MeterDomain

/// One discovered Claude Code config dir. Each config dir holds roughly one login.
public struct ClaudeAccount: Sendable, Hashable, Identifiable {
    /// The key of the default config dir, `~/.claude`.
    public static let defaultID: AccountID = "claude"

    /// The account key: the folder name without its leading dot, such as `claude` or
    /// `claude-work`. Settings, pins, and display names are stored under this key.
    public let id: AccountID
    /// The provider label: `default` for `claude`, `work` for `claude-work`.
    public let name: String
    /// The config dir as found or configured. Symbolic links are not resolved.
    public let directory: URL
    /// The account uses the `claude` key. Claude Code's legacy Keychain item belongs to it.
    public let isDefault: Bool
    /// False when the user turned the account off. Disabled accounts are listed but not read.
    public let isEnabled: Bool
    /// A problem with the folder itself, such as a configured folder that is no longer a
    /// Claude config dir. Such an account is listed so that the user can remove it, but it is
    /// not read.
    public let issue: UsageIssue?

    /// Makes an account value, for example for previews and tests.
    public init(
        id: AccountID, name: String, directory: URL, isDefault: Bool, isEnabled: Bool,
        issue: UsageIssue? = nil
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.isDefault = isDefault
        self.isEnabled = isEnabled
        self.issue = issue
    }
}

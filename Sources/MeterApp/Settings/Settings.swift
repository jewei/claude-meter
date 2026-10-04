import Foundation
import MeterDomain

/// Every user preference, stored as one JSON value.
///
/// To add a setting, add a stored property with a default value to the right group. Stored
/// JSON that lacks the property decodes with the default (see ``SettingsCodec``), so no
/// migration is needed.
public struct Settings: Codable, Equatable, Sendable {
    /// Polling is paused by the user. Readings stay visible.
    public var isPaused = false
    /// The user has seen the welcome screen and opened Settings once.
    public var hasCompletedOnboarding = false
    public var claude = ClaudeSettings()
    public var codex = CodexSettings()
    public var cursor = SourceSettings()
    public var grok = SourceSettings()
    public var appearance = AppearanceSettings()
    public var menuBar = MenuBarSettings()
    public var cards = CardSettings()
    /// Write a private log file in `~/Library/Logs/ClaudeMeter`.
    public var writesLogFile = false

    public init() {}

    /// Providers whose source switch is on.
    public var enabledProviders: Set<ProviderID> {
        var enabled: Set<ProviderID> = []
        if claude.isEnabled { enabled.insert(.claude) }
        if codex.isEnabled { enabled.insert(.codex) }
        if cursor.isEnabled { enabled.insert(.cursor) }
        if grok.isEnabled { enabled.insert(.grok) }
        return enabled
    }

    /// The user-chosen display name for an account, if any.
    public func displayName(for provider: ProviderID, account: AccountID) -> String? {
        let names =
            switch provider {
            case .claude: claude.accountNames
            case .codex: codex.accountNames
            case .cursor, .grok: [AccountID: String]()
            }
        let name = names[account]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }
}

public struct ClaudeSettings: Codable, Equatable, Sendable {
    public enum Connection: String, Codable, Sendable, CaseIterable {
        /// Not connected. Claude shows a prompt to connect in Settings.
        case off
        /// Read Claude Code's own Keychain credentials.
        case automatic
        /// Use OAuth tokens that the user pasted, stored in this app's Keychain item.
        case manual
    }

    public var isEnabled = true
    public var connection = Connection.off
    /// The user confirmed that the app may read Claude Code's Keychain items.
    public var hasConfirmedKeychainAccess = false
    /// Config dirs that the user added, as canonical paths.
    public var extraDirectories: [String] = []
    public var disabledAccounts: Set<AccountID> = []
    public var accountNames: [AccountID: String] = [:]
    /// A plan badge for accounts whose login reports no plan.
    public var planOverrides: [AccountID: String] = [:]

    public init() {}
}

public struct CodexSettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    /// Codex homes that the user added, as canonical paths.
    public var extraHomes: [String] = []
    public var accountNames: [AccountID: String] = [:]

    public init() {}
}

public struct SourceSettings: Codable, Equatable, Sendable {
    public var isEnabled = false

    public init() {}
}

public struct AppearanceSettings: Codable, Equatable, Sendable {
    public enum CardStyle: String, Codable, Sendable, CaseIterable {
        case rings
        case bars
    }

    /// Whether numbers and fills show what is left or what is used.
    public enum MeterMode: String, Codable, Sendable, CaseIterable {
        case energyLeft
        case used
    }

    /// Which window the menu-bar number shows.
    public enum MenuBarWindow: String, Codable, Sendable, CaseIterable {
        /// The session window, or the weekly window when the account has no session window.
        case session
        case weekly
        case both
    }

    public var cardStyle = CardStyle.rings
    public var meterMode = MeterMode.energyLeft
    public var menuBarWindow = MenuBarWindow.session
    public var thresholds = Thresholds.standard

    public init() {}
}

public struct MenuBarSettings: Codable, Equatable, Sendable {
    /// The provider that owns the menu bar, the hero, and the first card. Claude or Codex.
    public var provider = ProviderID.claude
    /// An exact account per provider. Without a pin, the account nearest its limit wins.
    public var pinnedAccounts: [ProviderID: AccountID] = [:]

    public init() {}

    public var pinnedAccount: AccountID? {
        pinnedAccounts[provider]
    }
}

public struct CardSettings: Codable, Equatable, Sendable {
    /// The user's card order. Empty means automatic order.
    public var order: [CardID] = []
    /// Collapsible cards that are open.
    public var expanded: Set<CardID> = []

    public init() {}
}

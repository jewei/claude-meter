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

    /// Providers in use: the source switch is on and, for Claude, a connection is chosen. Only
    /// these refresh, show cards, and can own the menu bar. Claude with its switch on but no
    /// connection has nothing to read, so it stays quiet until the user connects it
    /// (``ClaudeSettings/needsConnection``).
    public var enabledProviders: Set<ProviderID> {
        Set(ProviderID.allCases.filter(isInUse))
    }

    /// Whether `provider` is in use; see ``enabledProviders``.
    public func isInUse(_ provider: ProviderID) -> Bool {
        switch provider {
        case .claude: claude.isEnabled && claude.connection != .off
        case .codex: codex.isEnabled
        case .cursor: cursor.isEnabled
        case .grok: grok.isEnabled
        }
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

    /// The user turned off tracking of `account` in Settings > Data. Only a Claude config dir
    /// can be turned off, and only automatic mode lists config dirs. The provider never turns
    /// off the default account, so callers check this only for an account that it did not list.
    func isUntracked(_ account: AccountID, of provider: ProviderID) -> Bool {
        provider == .claude && claude.connection == .automatic
            && claude.disabledAccounts.contains(account)
    }

    /// Removes everything stored for an account that the user removed: its display name, plan
    /// badge, off switch, pin, saved card position, and open state.
    mutating func forgetAccount(_ account: AccountID, of provider: ProviderID) {
        switch provider {
        case .claude:
            claude.accountNames[account] = nil
            claude.planOverrides[account] = nil
            claude.disabledAccounts.remove(account)
        case .codex:
            codex.accountNames[account] = nil
        case .cursor, .grok:
            break
        }
        if menuBar.pinnedAccounts[provider] == account {
            menuBar.pinnedAccounts[provider] = nil
        }
        let card = CardID.account(provider, account)
        cards.order.removeAll { $0 == card }
        cards.expanded.remove(card)
    }
}

public struct ClaudeSettings: Codable, Equatable, Sendable {
    public enum Connection: String, Codable, Sendable, CaseIterable {
        /// Not connected. Claude shows a prompt to connect in Settings.
        case off
        /// Read Claude Code's own Keychain credentials, one login per config dir.
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

    /// The Claude switch is on but no connection is chosen, so Claude is not in use yet.
    public var needsConnection: Bool {
        isEnabled && connection == .off
    }
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
    /// The provider chosen to own the menu bar, the hero, and the first card. Claude or Codex.
    /// ``PresentationContext/mainProvider`` decides which provider owns them now.
    public var provider = ProviderID.claude
    /// An exact account per provider. Without a pin, the account nearest its limit wins.
    public var pinnedAccounts: [ProviderID: AccountID] = [:]

    public init() {}
}

public struct CardSettings: Codable, Equatable, Sendable {
    /// The user's card order. Empty means automatic order.
    public var order: [CardID] = []
    /// Collapsible cards that are open.
    public var expanded: Set<CardID> = []

    public init() {}
}

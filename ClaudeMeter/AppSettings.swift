import ClaudeMeterCore
import ClaudeMeterProviders
import Foundation

extension String {
    /// "it-oneone" -> "It Oneone": replace separators with spaces and title-case words.
    var friendlyAccountLabel: String {
        replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

enum AppSettings {
    static let isActiveKey = "isActive"
    static let statuslineSourceEnabledKey = "statuslineSourceEnabled"
    static let oauthSourceEnabledKey = "oauthSourceEnabled"
    static let cursorSourceEnabledKey = "cursorSourceEnabled"
    static let codexSourceEnabledKey = "codexSourceEnabled"
    static let grokSourceEnabledKey = "grokSourceEnabled"
    static let codexSourceModeKey = "codexSourceMode"
    static let configuredCodexHomesKey = "configuredCodexHomes"
    static let codexAccountNamesKey = "codexAccountNames"
    static let oauthModeKey = AppGroupConfig.oauthModeKey

    static var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: isActiveKey) }
        set { UserDefaults.standard.set(newValue, forKey: isActiveKey) }
    }

    static var statuslineSourceEnabled: Bool {
        get { boolDefaultingTrue(forKey: statuslineSourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: statuslineSourceEnabledKey) }
    }

    static var oauthSourceEnabled: Bool {
        get { boolDefaultingTrue(forKey: oauthSourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: oauthSourceEnabledKey) }
    }

    /// Cursor defaults off because it has a different billing model.
    static var cursorSourceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: cursorSourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: cursorSourceEnabledKey) }
    }

    /// Codex defaults off and appears as a separate provider card.
    static var codexSourceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: codexSourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: codexSourceEnabledKey) }
    }

    /// Grok defaults off and appears as a separate provider card.
    static var grokSourceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: grokSourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: grokSourceEnabledKey) }
    }

    static var codexSourceMode: CodexSourceMode {
        get { CodexSourceMode.normalized(UserDefaults.standard.string(forKey: codexSourceModeKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: codexSourceModeKey) }
    }

    static var configuredCodexHomes: [String] {
        get { UserDefaults.standard.stringArray(forKey: configuredCodexHomesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: configuredCodexHomesKey) }
    }

    static var codexAccountNames: [String: String] {
        get {
            UserDefaults.standard.dictionary(forKey: codexAccountNamesKey) as? [String: String]
                ?? [:]
        }
        set { UserDefaults.standard.set(newValue, forKey: codexAccountNamesKey) }
    }

    static func codexAccounts(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [CodexAccount] {
        let implicitPath =
            env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let paths = [implicitPath] + configuredCodexHomes
        let names = codexAccountNames
        var seen = Set<String>()
        return paths.enumerated().compactMap { index, path in
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted else { return nil }
            return CodexAccount(home: url, isImplicit: index == 0, customName: names[url.path])
        }
    }

    static let attentionStopEnabledKey = "attentionStopEnabled"
    static let attentionNotificationEnabledKey = "attentionNotificationEnabled"
    static let attentionLimitHitEnabledKey = "attentionLimitHitEnabled"
    static let predictiveNotificationsEnabledKey = "predictiveNotificationsEnabled"

    static var attentionStopEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: attentionStopEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: attentionStopEnabledKey) }
    }

    static var attentionNotificationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: attentionNotificationEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: attentionNotificationEnabledKey) }
    }

    static var attentionLimitHitEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: attentionLimitHitEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: attentionLimitHitEnabledKey) }
    }

    static var enabledAttentionEvents: Set<String> {
        var events = Set<String>()
        if attentionStopEnabled { events.insert("Stop") }
        if attentionNotificationEnabled { events.insert("Notification") }
        if attentionLimitHitEnabled { events.insert("StopFailure") }
        return events
    }

    static var attentionEnabled: Bool { !enabledAttentionEvents.isEmpty }

    static var hasClaudeSource: Bool {
        statuslineSourceEnabled || oauthSourceEnabled
    }

    static var hasEnabledDataSource: Bool {
        hasClaudeSource || cursorSourceEnabled || codexSourceEnabled || grokSourceEnabled
    }

    private static func boolDefaultingTrue(forKey key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}

struct CodexAccount: Identifiable, Sendable, Equatable {
    let home: URL
    let isImplicit: Bool
    let customName: String?

    var id: String { home.path }
    var defaultName: String { isImplicit ? "Codex" : home.lastPathComponent }
    var displayName: String {
        guard let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return defaultName }
        return name
    }
}

/// Immutable settings captured once at the start of a poll. Every provider in a
/// cycle therefore sees the same source selection, account list, and Codex mode.
struct PollConfiguration: Sendable {
    let generation: Int
    let claudeEnabled: Bool
    let cursorEnabled: Bool
    let codexEnabled: Bool
    let grokEnabled: Bool
    let codexMode: CodexSourceMode
    let codexAccounts: [CodexAccount]

    init(generation: Int) {
        self.generation = generation
        claudeEnabled = AppSettings.hasClaudeSource
        cursorEnabled = AppSettings.cursorSourceEnabled
        codexEnabled = AppSettings.codexSourceEnabled
        grokEnabled = AppSettings.grokSourceEnabled
        codexMode = AppSettings.codexSourceMode
        codexAccounts = codexEnabled ? AppSettings.codexAccounts() : []
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

import Foundation
import MeterDomain
import MeterPlatform

/// Finds Claude Code config dirs and derives their account keys and labels.
///
/// Claude Code reads its config from `$CLAUDE_CONFIG_DIR`, `~/.claude` by default. Users who
/// run several logins point each shell alias at its own dir, such as `~/.claude-work`. Account
/// keys are stored in settings, so the key algorithm must never change.
enum ConfigDirectoryScanner {
    /// Characters kept in an account key. Other characters are removed.
    private static let keyCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".unicodeScalars)

    /// The account key of a config dir: its folder name without one leading dot, with only
    /// `[A-Za-z0-9._-]` kept. An empty result is `claude`.
    static func accountID(for directory: URL) -> AccountID {
        var name = directory.lastPathComponent
        if name.hasPrefix(".") { name.removeFirst() }
        let kept = String(
            String.UnicodeScalarView(name.unicodeScalars.filter(keyCharacters.contains)))
        return AccountID(kept.isEmpty ? ClaudeAccount.defaultID.rawValue : kept)
    }

    /// The provider label of an account key: `default` for `claude`, the part after `claude-`
    /// for `claude-<name>`, otherwise the key itself.
    static func name(for id: AccountID) -> String {
        let key = id.rawValue
        if id == ClaudeAccount.defaultID { return "default" }
        let prefix = "claude-"
        if key.hasPrefix(prefix), key.count > prefix.count {
            return String(key.dropFirst(prefix.count))
        }
        return key
    }

    /// The absolute path with symbolic links resolved and no trailing slash. Claude Code hashes
    /// this form of the path into its Keychain service name.
    static func canonicalPath(_ directory: URL) -> String {
        directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A directory that holds `settings.json` or `projects`.
    static func isConfigDirectory(_ url: URL) -> Bool {
        LocalFile.isDirectory(url) && hasConfigContents(url)
    }

    /// Every config dir: `~/.claude`, other `~/.claude-*` dirs that hold `settings.json` or
    /// `projects`, and the configured dirs. Disabled accounts are included and marked.
    ///
    /// Two dirs with the same resolved path are one account. Two dirs with the same key keep
    /// one: `~/.claude` owns `claude`, then a configured dir wins, then the smaller path. The
    /// result lists the default account first, then the others by key.
    static func discover(home: URL, configuration: ClaudeConfiguration) -> [ClaudeAccount] {
        let defaultDirectory = home.appending(path: ".claude", directoryHint: .isDirectory)
        let hasDefault = LocalFile.isDirectory(defaultDirectory)
        var candidates = scannedDirectories(in: home).map { Candidate($0, isConfigured: false) }
        if hasDefault {
            candidates.append(Candidate(defaultDirectory, isConfigured: false))
        }
        candidates += configuration.extraDirectories.map {
            Candidate(expandingTilde($0, home: home), isConfigured: true)
        }

        var seenPaths = Set<String>()
        var seenKeys = Set<AccountID>()
        var accounts: [ClaudeAccount] = []
        func consider(_ candidate: Candidate) {
            guard seenPaths.insert(candidate.path).inserted,
                seenKeys.insert(candidate.id).inserted
            else { return }
            accounts.append(
                ClaudeAccount(
                    id: candidate.id, name: name(for: candidate.id), directory: candidate.url,
                    isDefault: candidate.id == ClaudeAccount.defaultID,
                    isEnabled: configuration.isEnabled(candidate.id),
                    issue: candidate.isConfigured ? folderIssue(candidate.url) : nil))
        }

        if hasDefault { consider(Candidate(defaultDirectory, isConfigured: false)) }
        let configuredPaths = Set(candidates.filter(\.isConfigured).map(\.path))
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            let lhsConfigured = configuredPaths.contains(lhs.path)
            let rhsConfigured = configuredPaths.contains(rhs.path)
            if lhsConfigured != rhsConfigured { return lhsConfigured }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return !lhs.isConfigured && rhs.isConfigured
        }
        for candidate in ordered { consider(candidate) }
        return accounts
    }

    private struct Candidate {
        let url: URL
        let isConfigured: Bool
        let path: String
        let id: AccountID

        init(_ url: URL, isConfigured: Bool) {
            self.url = url
            self.isConfigured = isConfigured
            self.path = ConfigDirectoryScanner.canonicalPath(url)
            self.id = ConfigDirectoryScanner.accountID(for: url)
        }
    }

    private static func scannedDirectories(in home: URL) -> [URL] {
        let children =
            (try? FileManager.default.contentsOfDirectory(
                at: home, includingPropertiesForKeys: nil, options: [])) ?? []
        return children.filter { child in
            let name = child.lastPathComponent
            guard name == ".claude" || name.hasPrefix(".claude-"), LocalFile.isDirectory(child)
            else { return false }
            return name == ".claude" || hasConfigContents(child)
        }
    }

    private static func hasConfigContents(_ directory: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: directory.appending(path: "settings.json").path)
            || manager.fileExists(atPath: directory.appending(path: "projects").path)
    }

    /// A configured dir stays listed after it stops looking like a config dir, so that the
    /// user can see the problem and remove it.
    private static func folderIssue(_ directory: URL) -> UsageIssue? {
        if !LocalFile.isDirectory(directory) {
            return UsageIssue(
                "This folder no longer exists. Remove it in Settings.", needsAction: true)
        }
        if !hasConfigContents(directory) {
            return UsageIssue(
                "This folder is not a Claude config dir (no settings.json or projects). "
                    + "Remove it in Settings.",
                needsAction: true)
        }
        return nil
    }

    private static func expandingTilde(_ url: URL, home: URL) -> URL {
        let path = url.path
        guard path == "~" || path.hasPrefix("~/") else { return url }
        return home.appending(path: String(path.dropFirst(2)), directoryHint: .isDirectory)
    }
}

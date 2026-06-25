import Foundation

/// One discovered Claude Code config directory — roughly one account.
///
/// Claude Code reads its config from `$CLAUDE_CONFIG_DIR` (default `~/.claude`).
/// Power users run several accounts via shell aliases like
/// `CLAUDE_CONFIG_DIR=~/.claude-work claude`, each with its own `settings.json`
/// and `projects/`. Rate limits are *per account*, so the meter must keep them
/// separate rather than blending them.
public struct AccountConfig: Sendable, Equatable, Identifiable {
    /// Stable account key — see `ConfigDirDiscovery.accountKey(for:)`.
    public let id: String
    /// Human-facing label derived from the key (e.g. `default`, `it-oneone`).
    public let label: String
    /// The config directory itself (`~/.claude`, `~/.claude-work`, …).
    public let configDir: URL

    public var settingsPath: URL { configDir.appendingPathComponent("settings.json") }
    public var projectsPath: URL { configDir.appendingPathComponent("projects") }

    public init(id: String, label: String, configDir: URL) {
        self.id = id
        self.label = label
        self.configDir = configDir
    }
}

/// Discovers the Claude config directories on this machine and derives their
/// account keys/labels. The key rule here is the single source of truth and MUST
/// stay byte-for-byte identical to the bridge bash snippet in `StatuslineBridge`,
/// because both name the same `~/.claude-meter/sessions/<key>/` subdirectory.
public enum ConfigDirDiscovery {

    /// ASCII allow-set matching `tr -cd "[:alnum:]._-"` under the C/POSIX locale.
    /// An explicit set is required: `Character.isLetter`/`isNumber` are Unicode-wide
    /// and would diverge from `tr`, breaking parity with the bash snippet.
    private static let allowedScalars: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>()
        for scalar in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
            .unicodeScalars
        {
            set.insert(scalar)
        }
        return set
    }()

    /// Canonical account key for a config dir: take the basename, strip exactly one
    /// leading `.`, keep only `[A-Za-z0-9._-]`, and fall back to `claude` if empty.
    ///
    /// `~/.claude` → `claude`, `~/.claude-it-oneone` → `claude-it-oneone`.
    /// Bash equivalent (must match — `LC_ALL=C` forces byte-oriented `tr` so it
    /// strips multibyte UTF-8 exactly like this ASCII allow-set):
    /// `A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude`
    public static func accountKey(for dir: URL) -> String {
        var name = dir.lastPathComponent
        if name.hasPrefix(".") { name.removeFirst() }
        let filtered = String(String.UnicodeScalarView(name.unicodeScalars.filter(allowedScalars.contains)))
        return filtered.isEmpty ? "claude" : filtered
    }

    /// Human label for an account key. `claude` → `default`; otherwise strip a
    /// leading `claude-` (`claude-it-oneone` → `it-oneone`). The payload JSON
    /// carries no org/email, so the dir name is the only stable identity we have.
    public static func label(forKey key: String) -> String {
        if key == "claude" { return "default" }
        if key.hasPrefix("claude-"), key.count > "claude-".count {
            return String(key.dropFirst("claude-".count))
        }
        return key
    }

    /// Discovers config directories: a heuristic scan of `~/.claude*` (dirs that
    /// hold a `settings.json` or `projects/`), unioned with `configuredDirs`, with
    /// `disabledKeys` removed and `~/.claude` always present. The default `claude`
    /// account is never dropped, even if listed in `disabledKeys`. Results are
    /// deduped by resolved path *and* account key, default first then key-sorted.
    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager fm: FileManager = .default,
        configuredDirs: [String] = [],
        disabledKeys: Set<String> = []
    ) -> [AccountConfig] {
        var candidates: [URL] = []

        // 1. Heuristic scan of immediate `~/.claude*` children (hidden, so do NOT
        //    pass `.skipsHiddenFiles`).
        if let children = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for child in children {
                let name = child.lastPathComponent
                guard name == ".claude" || name.hasPrefix(".claude-") else { continue }
                guard isDirectory(child, fm: fm) else { continue }
                if name == ".claude" || looksLikeConfigDir(child, fm: fm) {
                    candidates.append(child)
                }
            }
        }

        // Always include `~/.claude` when it exists, even if the scan missed it.
        let defaultDir = home.appendingPathComponent(".claude")
        if isDirectory(defaultDir, fm: fm),
            !candidates.contains(where: { sameResolvedPath($0, defaultDir) })
        {
            candidates.append(defaultDir)
        }

        // 2. User-configured custom dirs.
        for path in configuredDirs {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            if isDirectory(url, fm: fm) { candidates.append(url) }
        }

        // Dedup by resolved path and by account key; default account first, then
        // remaining accounts in stable key order.
        var seenPaths = Set<String>()
        var seenKeys = Set<String>()
        var configs: [AccountConfig] = []

        func consider(_ dir: URL) {
            let resolvedPath = dir.resolvingSymlinksInPath().standardizedFileURL.path
            guard seenPaths.insert(resolvedPath).inserted else { return }
            let key = accountKey(for: dir)
            // The default account is never disablable.
            guard key == "claude" || !disabledKeys.contains(key) else { return }
            guard seenKeys.insert(key).inserted else { return }
            configs.append(AccountConfig(id: key, label: label(forKey: key), configDir: dir))
        }

        for dir in candidates where accountKey(for: dir) == "claude" { consider(dir) }
        for dir in candidates.sorted(by: { accountKey(for: $0) < accountKey(for: $1) }) {
            consider(dir)
        }
        return configs
    }

    /// True when `dir` plausibly holds a Claude config (has `settings.json` or
    /// `projects/`) — used to validate a user-added custom config dir in Settings.
    public static func isPlausibleConfigDir(_ dir: URL, fileManager fm: FileManager = .default)
        -> Bool
    {
        isDirectory(dir, fm: fm) && looksLikeConfigDir(dir, fm: fm)
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func looksLikeConfigDir(_ dir: URL, fm: FileManager) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent("settings.json").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("projects").path)
    }

    private static func sameResolvedPath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

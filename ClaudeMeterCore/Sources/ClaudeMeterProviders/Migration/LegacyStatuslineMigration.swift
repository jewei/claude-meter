import Foundation

/// One-time removal of exact statusline commands shipped by Claude Meter.
public enum LegacyStatuslineMigration {
    static let completionKey = "didRemoveLegacyStatuslineBridge.v1"

    // Exact literals from b43e1d6 through b03da0e, including the unsanitized
    // per-session variant from 575b167. These strings are never executed.
    static let knownSnippets: [String] = [
        #"bash -c 'umask 077;I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;D=$HOME/.claude-meter/sessions/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#,
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;D=$HOME/.claude-meter/sessions/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#,
        #"bash -c 'I=$(cat);D=$HOME/.claude-meter/sessions;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#,
        #"bash -c 'I=$(cat);D=$HOME/.claude-meter;mkdir -p "$D" 2>/dev/null;T="$D/.sl-$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/statusline.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#,
        #"bash -c 'I=$(cat);D=$HOME/.claude-meter/sessions;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#,
    ]

    public static func runIfNeeded(configuredDirs: [String]) throws {
        guard !KeychainGateway.testFrameworkIsLoaded() else { return }
        try runIfNeeded(
            configuredDirs: configuredDirs,
            home: FileManager.default.homeDirectoryForCurrentUser, defaults: .standard)
    }

    static func runIfNeeded(configuredDirs: [String], home: URL, defaults: UserDefaults) throws {
        guard !defaults.bool(forKey: completionKey) else { return }
        let directories = try LegacyClaudeFiles.configDirectories(
            home: home, configuredDirs: configuredDirs)
        var firstError: Error?
        for directory in directories {
            do { try removeBridge(at: directory.appendingPathComponent("settings.json")) } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        try LegacyClaudeFiles.clearStatuslineFiles(in: home.appendingPathComponent(".claude-meter"))
        defaults.set(true, forKey: completionKey)
    }

    private static func removeBridge(at path: URL) throws {
        let original = try SettingsFile.read(at: path)
        guard let raw = original["statusLine"] else { return }
        guard var statusLine = raw as? [String: Any] else {
            throw SettingsFile.ParseError.rootNotObject
        }
        guard let rawCommand = statusLine["command"] else { return }
        guard let command = rawCommand as? String else {
            throw SettingsFile.ParseError.rootNotObject
        }
        let restored = removingKnownPrefixes(from: command)
        guard restored != command else { return }
        // The installer did not save the old interval. Preserve every other key,
        // including refreshInterval and type. An empty command has no capture work.
        statusLine["command"] = restored
        var settings = original
        settings["statusLine"] = statusLine
        guard NSDictionary(dictionary: try SettingsFile.read(at: path)).isEqual(to: original)
        else { throw BoundedRegularFileReader.ReadError.fileChanged }
        try SettingsFile.write(settings, at: path)
    }

    static func removingKnownPrefixes(from command: String) -> String {
        var remaining = command
        while true {
            if let prefix = knownSnippets.first(where: { remaining.hasPrefix($0 + " | ") }) {
                remaining = String(remaining.dropFirst(prefix.count + 3))
            } else if knownSnippets.contains(remaining)
                || knownSnippets.contains(where: { remaining == $0 + " > /dev/null" })
            {
                return ""
            } else {
                return remaining
            }
        }
    }
}

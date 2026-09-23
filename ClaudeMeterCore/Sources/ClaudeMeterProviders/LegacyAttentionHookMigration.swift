import Darwin
import Foundation

/// One-time removal of the commands shipped before attention support was removed.
/// Call off-main, before other legacy settings migrations.
public enum LegacyAttentionHookMigration {
    static let completionKey = "didRemoveLegacyAttentionHooks.v1"

    /// Exact literals from HookBridge at ece8d08. That revision includes every
    /// earlier command back to b7fbe1f. These strings are never executed.
    /// Order: v2 Herdr envelope; owner-only filename route; pre-umask route;
    /// unconditional terminal probe; PID marker; fixed-name marker.
    static let knownCommands: [String] = [
        #"bash -c 'umask 077;I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;P=$(printf "%s" "${TERM_PROGRAM:-}"|LC_ALL=C tr -cd "[:alnum:]._-" );P=${P:0:32};M=;if [ -n "$P" ];then Y=$(/bin/ps -o tty= -p $$ 2>/dev/null);Y=$(printf "%s" "$Y"|LC_ALL=C tr -cd "[:alnum:]._-");Y=${Y:0:32};X=${WEZTERM_PANE:-${ITERM_SESSION_ID:-${TERM_SESSION_ID:-${WARP_SESSION_ID:-}}}};X=$(printf "%s" "$X"|LC_ALL=C tr -cd "[:alnum:]._:-");X=${X:0:64};M=$(printf "%s\n%s\n%s\n%s\n%s\n%s" "$P" "$Y" "$X" "${HERDR_SOCKET_PATH:-}" "${HERDR_PANE_ID:-}" "${HERDR_STARTUP_CWD:-}"|/usr/bin/base64|tr -d "\n"|tr "/+" "_-"|tr -d "=");fi;T="$D/.tmp.$$";printf "{\"claude_meter_hook_version\":2,\"terminal_route\":\"%s\",\"event\":%s}" "$M" "$I">"$T"&&mv -f "$T" "$D/$S.$E.$$.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#,
        #"bash -c 'umask 077;I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;P=$(printf "%s" "${TERM_PROGRAM:-}"|LC_ALL=C tr -cd "[:alnum:]._-" );P=${P:0:32};M=;if [ -n "$P" ];then Y=$(/bin/ps -o tty= -p $$ 2>/dev/null);Y=$(printf "%s" "$Y"|LC_ALL=C tr -cd "[:alnum:]._-");Y=${Y:0:32};X=${WEZTERM_PANE:-${ITERM_SESSION_ID:-${TERM_SESSION_ID:-${WARP_SESSION_ID:-}}}};X=$(printf "%s" "$X"|LC_ALL=C tr -cd "[:alnum:]._:-");X=${X:0:64};M=$(printf "%s\n%s\n%s" "$P" "$Y" "$X"|/usr/bin/base64|tr -d "\n"|tr "/+" "_-"|tr -d "=");fi;[ -n "$M" ]&&M=.cmr-$M;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.$E.$$$M.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#,
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;P=$(printf "%s" "${TERM_PROGRAM:-}"|LC_ALL=C tr -cd "[:alnum:]._-" );P=${P:0:32};M=;if [ -n "$P" ];then Y=$(/bin/ps -o tty= -p $$ 2>/dev/null);Y=$(printf "%s" "$Y"|LC_ALL=C tr -cd "[:alnum:]._-");Y=${Y:0:32};X=${WEZTERM_PANE:-${ITERM_SESSION_ID:-${TERM_SESSION_ID:-${WARP_SESSION_ID:-}}}};X=$(printf "%s" "$X"|LC_ALL=C tr -cd "[:alnum:]._:-");X=${X:0:64};M=$(printf "%s\n%s\n%s" "$P" "$Y" "$X"|/usr/bin/base64|tr -d "\n"|tr "/+" "_-"|tr -d "=");fi;[ -n "$M" ]&&M=.cmr-$M;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.$E.$$$M.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#,
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;P=$(printf "%s" "${TERM_PROGRAM:-}"|LC_ALL=C tr -cd "[:alnum:]._-" );P=${P:0:32};Y=$(/bin/ps -o tty= -p $$ 2>/dev/null);Y=$(printf "%s" "$Y"|LC_ALL=C tr -cd "[:alnum:]._-");Y=${Y:0:32};X=${WEZTERM_PANE:-${ITERM_SESSION_ID:-${TERM_SESSION_ID:-${WARP_SESSION_ID:-}}}};X=$(printf "%s" "$X"|LC_ALL=C tr -cd "[:alnum:]._:-");X=${X:0:64};M=;[ -n "$P" ]&&M=$(printf "%s\n%s\n%s" "$P" "$Y" "$X"|/usr/bin/base64|tr -d "\n"|tr "/+" "_-"|tr -d "=");[ -n "$M" ]&&M=.cmr-$M;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.$E.$$$M.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#,
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.$E.$$.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#,
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.$E.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#,
    ]

    enum MigrationError: Error, LocalizedError {
        case unknownHookShape

        var errorDescription: String? {
            "Legacy hook cleanup could not read the Claude Code hook structure."
        }
    }

    /// Disabled accounts are included. Failures leave the flag unset for a later
    /// launch; successful directories need no further write on retry.
    public static func runIfNeeded(configuredDirs: [String]) throws {
        // Hosted app tests must never migrate the installed user's Claude settings.
        guard !KeychainGateway.testFrameworkIsLoaded() else { return }
        try runIfNeeded(
            configuredDirs: configuredDirs,
            home: FileManager.default.homeDirectoryForCurrentUser,
            defaults: .standard)
    }

    static func runIfNeeded(
        configuredDirs: [String],
        home: URL,
        defaults: UserDefaults
    ) throws {
        guard !defaults.bool(forKey: completionKey) else { return }
        let directories = try LegacyClaudeFiles.configDirectories(
            home: home, configuredDirs: configuredDirs)
        var firstError: Error?
        for directory in directories {
            do {
                try removeHooks(at: directory.appendingPathComponent("settings.json"))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }

        // The old snippets wrote only here. Reuse descriptor-anchored cleanup:
        // no links are followed, no directories are created, and empty dirs may remain.
        try? LegacyClaudeFiles.clearManagedSubdirectory(
            named: "events", in: home.appendingPathComponent(".claude-meter"))
        defaults.set(true, forKey: completionKey)
    }

    private static func removeHooks(at path: URL) throws {
        let original = try SettingsFile.read(at: path)
        guard let rawHooks = original["hooks"] else { return }
        guard var hooks = rawHooks as? [String: Any] else {
            throw MigrationError.unknownHookShape
        }
        var changed = false
        for event in ["Stop", "Notification", "StopFailure"] {
            guard let rawGroups = hooks[event] else { continue }
            guard let groups = rawGroups as? [[String: Any]] else {
                throw MigrationError.unknownHookShape
            }
            var eventChanged = false
            var keptGroups: [[String: Any]] = []
            for group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else {
                    throw MigrationError.unknownHookShape
                }
                let kept = entries.filter { entry in
                    guard entry["type"] as? String == "command",
                        let command = entry["command"] as? String
                    else { return true }
                    return !knownCommands.contains(command)
                }
                if kept.count == entries.count {
                    keptGroups.append(group)
                } else {
                    eventChanged = true
                    if !kept.isEmpty {
                        var remaining = group
                        remaining["hooks"] = kept
                        keptGroups.append(remaining)
                    }
                }
            }
            // Preserve originally empty event arrays and groups.
            if eventChanged {
                changed = true
                if keptGroups.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = keptGroups
                }
            }
        }
        guard changed else { return }
        var settings = original
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        // Reject changes made by another editor while we parsed the file.
        guard NSDictionary(dictionary: try SettingsFile.read(at: path)).isEqual(to: original)
        else { throw BoundedRegularFileReader.ReadError.fileChanged }
        try SettingsFile.write(settings, at: path)
    }

}

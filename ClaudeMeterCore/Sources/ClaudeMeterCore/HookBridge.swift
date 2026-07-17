import Foundation

/// Manages Claude Code **hooks** that signal when a session needs the user's
/// attention. Mirrors `StatuslineBridge`, but instead of a single `statusLine`
/// string it merges entries into the `hooks` object of each config dir's
/// `settings.json`:
///
/// - `Stop` — fires when the agent finishes a turn ("your move").
/// - `Notification` — fires when Claude Code needs permission or has gone idle.
///
/// Each hook command atomically writes Claude Code's stdin payload to
/// `~/.claude-meter/events/<accountKey>/<session_id>.<event>.json`. The app's
/// watcher turns those markers into the menu-bar attention state + notifications.
///
/// Unlike the statusline (which owns its whole string), hooks are an array the
/// user may also populate, so install/uninstall **only** touches our own entry —
/// identified by an exact command match — and preserves every other hook.
public enum HookBridge: Sendable {

    // MARK: - Paths

    static let eventsDir: URL = StatuslineBridge.dataDir.appendingPathComponent("events")

    /// Per-account subdirectory holding one account's event markers.
    static func eventsDir(for accountKey: String) -> URL {
        eventsDir.appendingPathComponent(accountKey)
    }

    static let defaultConfigDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")

    // MARK: - Events we manage

    /// The hook events this bridge installs. Anything else in `settings.json`
    /// `hooks` is left untouched.
    public static let managedEvents = ["Stop", "Notification", "StopFailure"]

    // MARK: - Hook snippet

    /// Inline bash snippet (one snippet serves every event — it reads
    /// `hook_event_name` from stdin to key the filename). Derives the account key
    /// from `$CLAUDE_CONFIG_DIR` exactly like the statusline bridge, atomically
    /// writes stdin to `events/<accountKey>/<session_id>.<event>.json`, and always
    /// exits 0 so a `Stop` hook can never block Claude Code. It does **not** echo
    /// stdin (hooks render nothing).
    /// The marker filename includes `$$` (the hook process's PID, unique per fire)
    /// plus a compact route suffix containing `TERM_PROGRAM`, the controlling TTY,
    /// and a client-specific locator. This keeps the hook payload byte-identical to
    /// Claude Code's JSON while giving notification clicks a terminal to focus.
    static let hookSnippet =
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;P=$(printf "%s" "${TERM_PROGRAM:-}"|LC_ALL=C tr -cd "[:alnum:]._-" );P=${P:0:32};Y=$(/bin/ps -o tty= -p $$ 2>/dev/null);Y=$(printf "%s" "$Y"|LC_ALL=C tr -cd "[:alnum:]._-");Y=${Y:0:32};X=${WEZTERM_PANE:-${ITERM_SESSION_ID:-${TERM_SESSION_ID:-${WARP_SESSION_ID:-}}}};X=$(printf "%s" "$X"|LC_ALL=C tr -cd "[:alnum:]._:-");X=${X:0:64};M=;[ -n "$P" ]&&M=$(printf "%s\n%s\n%s" "$P" "$Y" "$X"|/usr/bin/base64|tr -d "\n"|tr "/+" "_-"|tr -d "=");[ -n "$M" ]&&M=.cmr-$M;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.$E.$$$M.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#

    /// Snippets from earlier versions, recognised so install migrates them to the
    /// current snippet (and uninstall removes them) instead of leaving duplicates.
    /// First entry: the pre-route snippet; second: the pre-PID fixed filename.
    static let legacyHookSnippets: [String] = [
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.$E.$$.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#,
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.$E.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#
    ]

    private static var allHookSnippets: [String] { [hookSnippet] + legacyHookSnippets }

    // MARK: - Install / uninstall

    /// Convenience shim — installs into the default `~/.claude` config dir.
    public static func install(events: Set<String>) throws {
        try install(configDirs: [defaultConfigDir], events: events)
    }

    /// Reconciles our hook entries in each config dir's `settings.json` to match
    /// `events` (the enabled hook events): present for events in the set, absent for
    /// the rest. Idempotent — only writes when something actually changes — and
    /// preserves all of the user's own hooks. Dirs that don't exist are skipped; a
    /// dir whose `settings.json` is invalid JSON is skipped (its error surfaced
    /// after) without blocking the others.
    public static func install(configDirs: [URL], events: Set<String>) throws {
        // The events dir is created lazily by the hook snippet's `mkdir -p` on first
        // fire — install must not touch ~/.claude-meter (keeps tests off the real dir).
        var firstError: Error?
        for dir in configDirs {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            do {
                try installOne(
                    settingsPath: dir.appendingPathComponent("settings.json"), events: events)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// Convenience shim — removes our hooks from the default `~/.claude` config dir.
    public static func uninstall() throws {
        try uninstall(configDirs: [defaultConfigDir])
    }

    /// Removes our hook entries from each config dir's `settings.json`. Touches only
    /// the given config dirs — the events dir is cleaned by the app on disable (this
    /// keeps the operation off the real ~/.claude-meter when called from tests).
    public static func uninstall(configDirs: [URL]) throws {
        var firstError: Error?
        for dir in configDirs {
            let settingsPath = dir.appendingPathComponent("settings.json")
            guard FileManager.default.fileExists(atPath: settingsPath.path) else { continue }
            do {
                try installOne(settingsPath: settingsPath, events: [])
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private static func installOne(settingsPath: URL, events: Set<String>) throws {
        var settings = try readSettings(at: settingsPath)
        let hadHooks = settings["hooks"] != nil
        // If `hooks` exists but isn't an object, leave it alone — never overwrite a
        // shape we don't understand (that would destroy the user's data).
        if hadHooks, !(settings["hooks"] is [String: Any]) { return }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var changed = false
        for event in managedEvents {
            if reconcileEvent(event, want: events.contains(event), in: &hooks) {
                changed = true
            }
        }
        guard changed else { return }

        if hooks.isEmpty {
            if hadHooks { settings.removeValue(forKey: "hooks") }
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings, at: settingsPath)
    }

    /// Reconciles a single event's hook list to the desired state, preserving the
    /// user's own hooks. Works at the *command* level: it strips our command from
    /// each group (keeping the user's other commands in that group) and drops only
    /// groups that become empty, rather than discarding a whole group that merely
    /// contains our command alongside the user's. Returns true when it changed.
    ///
    /// Our group is always (re-)appended last; since we are the only writer that
    /// adds it, it stays last in steady state (no churn), and our marker-writing
    /// hook is order-independent so a one-time reorder is harmless.
    static func reconcileEvent(_ event: String, want: Bool, in hooks: inout [String: Any]) -> Bool {
        // Unexpected shape → leave untouched (don't clobber user data).
        if let raw = hooks[event], !(raw is [[String: Any]]) { return false }
        let current = (hooks[event] as? [[String: Any]]) ?? []

        var preserved: [[String: Any]] = []
        for group in current {
            guard let inner = group["hooks"] as? [[String: Any]] else {
                preserved.append(group)  // unknown group shape — keep verbatim
                continue
            }
            let userInner = inner.filter { !isOurCommand($0) }
            if userInner.count == inner.count {
                preserved.append(group)  // nothing of ours here
            } else if !userInner.isEmpty {
                var stripped = group
                stripped["hooks"] = userInner  // keep the user's commands, drop ours
                preserved.append(stripped)
            }
            // else: the group held only our command → drop it
        }
        let desired = want ? preserved + [ourGroup()] : preserved

        if NSArray(array: current).isEqual(NSArray(array: desired)) { return false }
        if desired.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = desired
        }
        return true
    }

    /// A single hook entry is "ours" when its command matches one of our snippets
    /// (current or legacy).
    private static func isOurCommand(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return allHookSnippets.contains(command)
    }

    private static func ourGroup() -> [String: Any] {
        ["hooks": [["type": "command", "command": hookSnippet]]]
    }

    // MARK: - Settings helpers

    private static func readSettings(at settingsPath: URL) throws -> [String: Any] {
        try SettingsFile.read(at: settingsPath)
    }

    private static func writeSettings(_ settings: [String: Any], at settingsPath: URL) throws {
        try SettingsFile.write(settings, at: settingsPath)
    }
}

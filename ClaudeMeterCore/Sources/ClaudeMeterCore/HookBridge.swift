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
    public static let managedEvents = ["Stop", "Notification"]

    // MARK: - Hook snippet

    /// Inline bash snippet (one snippet serves every event — it reads
    /// `hook_event_name` from stdin to key the filename). Derives the account key
    /// from `$CLAUDE_CONFIG_DIR` exactly like the statusline bridge, atomically
    /// writes stdin to `events/<accountKey>/<session_id>.<event>.json`, and always
    /// exits 0 so a `Stop` hook can never block Claude Code. It does **not** echo
    /// stdin (hooks render nothing).
    static let hookSnippet =
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;E=$(printf "%s" "$I"|sed -n "s/.*\"hook_event_name\":\"\([^\"]*\)\".*/\1/p");E=$(printf "%s" "$E"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$E" ]&&E=event;D=$HOME/.claude-meter/events/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.$E.json" 2>/dev/null||rm -f "$T" 2>/dev/null;exit 0'"#

    /// Snippets from earlier versions, recognised so install can migrate them and
    /// uninstall can remove them. (None yet — slot kept for forward-compat.)
    static let legacyHookSnippets: [String] = []

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
        if !events.isEmpty {
            try? FileManager.default.createDirectory(
                at: eventsDir, withIntermediateDirectories: true)
        }
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

    /// Removes our hook entries from each config dir and deletes the events dir.
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
        try? FileManager.default.removeItem(at: eventsDir)
        if let firstError { throw firstError }
    }

    private static func installOne(settingsPath: URL, events: Set<String>) throws {
        var settings = try readSettings(at: settingsPath)
        let hadHooks = settings["hooks"] != nil
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
    /// user's own groups. Returns true when the list actually changed.
    static func reconcileEvent(_ event: String, want: Bool, in hooks: inout [String: Any]) -> Bool {
        let current = (hooks[event] as? [[String: Any]]) ?? []
        let userGroups = current.filter { !groupIsOurs($0) }
        let desired = want ? userGroups + [ourGroup()] : userGroups

        if NSArray(array: current).isEqual(NSArray(array: desired)) { return false }
        if desired.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = desired
        }
        return true
    }

    /// A hook group is "ours" when it contains a command matching one of our
    /// snippets (current or legacy).
    private static func groupIsOurs(_ group: [String: Any]) -> Bool {
        let inner = (group["hooks"] as? [[String: Any]]) ?? []
        return inner.contains { entry in
            (entry["command"] as? String).map { allHookSnippets.contains($0) } ?? false
        }
    }

    private static func ourGroup() -> [String: Any] {
        ["hooks": [["type": "command", "command": hookSnippet]]]
    }

    // MARK: - Settings helpers (mirror StatuslineBridge)

    private static func readSettings(at settingsPath: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return [:] }
        return try parseSettingsData(Data(contentsOf: settingsPath))
    }

    internal static func parseSettingsDataForTesting(_ data: Data?) throws -> [String: Any] {
        try parseSettingsData(data)
    }

    private static func parseSettingsData(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !data.isEmpty else { throw HookBridgeError.invalidSettingsJSON }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HookBridgeError.invalidSettingsJSON
        }
        guard let settings = object as? [String: Any] else {
            throw HookBridgeError.settingsRootNotObject
        }
        return settings
    }

    private static func writeSettings(_ settings: [String: Any], at settingsPath: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        let dir = settingsPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: settingsPath, options: .atomic)
    }
}

private enum HookBridgeError: Error, LocalizedError {
    case invalidSettingsJSON
    case settingsRootNotObject

    var errorDescription: String? {
        switch self {
        case .invalidSettingsJSON:
            "Claude Code settings.json is not valid JSON; attention hooks were not installed."
        case .settingsRootNotObject:
            "Claude Code settings.json must contain a JSON object; attention hooks were not installed."
        }
    }
}

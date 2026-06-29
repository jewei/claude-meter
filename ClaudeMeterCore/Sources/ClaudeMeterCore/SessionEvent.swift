import Foundation

/// One attention event emitted by a Claude Code hook (see `HookBridge`): the agent
/// finished a turn (`Stop`) or needs the user (`Notification`). Parsed from a marker
/// file under `~/.claude-meter/events/<accountKey>/<session_id>.<event>.json`.
public struct SessionEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case stop = "Stop"
        case notification = "Notification"
        case other = "other"
    }

    public let kind: Kind
    /// Config-dir account key the event came from (the marker's subdirectory).
    public let accountKey: String
    public let sessionId: String?
    /// Working directory of the session — the project the user was in.
    public let cwd: String?
    /// `Notification` message text (e.g. "Claude needs your permission to use Bash").
    public let message: String?
    /// File modification time — when the hook fired.
    public let capturedAt: Date

    public init(
        kind: Kind, accountKey: String, sessionId: String?, cwd: String?, message: String?,
        capturedAt: Date
    ) {
        self.kind = kind
        self.accountKey = accountKey
        self.sessionId = sessionId
        self.cwd = cwd
        self.message = message
        self.capturedAt = capturedAt
    }

    /// Last path component of `cwd` — the project name, for display.
    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// Reads (and consumes) the attention markers written by the hook bridge. Each
/// marker is a one-shot event, so draining deletes the files; the live "needs
/// attention" state lives in the app, not on disk.
public enum SessionEventStore {

    /// Reads every fresh marker under the events dir, deletes all markers it sees
    /// (fresh *and* stale, so a backlog never accumulates), and returns the fresh
    /// events. Markers older than `maxAge` are dropped silently — on app launch we
    /// don't want to replay a pile of old "your turn" pings.
    public static func drain(
        disabledAccountKeys: Set<String> = [], now: Date = Date(), maxAge: TimeInterval = 120
    ) -> [SessionEvent] {
        drain(
            eventsRoot: HookBridge.eventsDir, disabledAccountKeys: disabledAccountKeys, now: now,
            maxAge: maxAge)
    }

    /// Testable core with an injectable root.
    ///
    /// `disabledAccountKeys` are skipped entirely — a disabled account's hook may
    /// still be writing markers until it's reconciled away, and (per AGENTS.md) the
    /// read path must filter disabled accounts too, not just discovery.
    static func drain(
        eventsRoot: URL, disabledAccountKeys: Set<String>, now: Date, maxAge: TimeInterval
    ) -> [SessionEvent] {
        let fm = FileManager.default
        guard
            let subdirs = try? fm.contentsOfDirectory(
                at: eventsRoot, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        var events: [SessionEvent] = []
        for sub in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let accountKey = sub.lastPathComponent
            let isDisabled = disabledAccountKeys.contains(accountKey)
            guard
                let files = try? fm.contentsOfDirectory(
                    at: sub, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == "json" {
                let mod =
                    (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                // Unknown mtime → assume fresh (don't drop a real event to a stat blip).
                let fresh = mod.map { now.timeIntervalSince($0) < maxAge } ?? true
                if fresh {
                    // Only consume on a successful parse; a transient read/parse
                    // failure leaves the marker for the next tick (it's cleaned once
                    // it ages past maxAge). Disabled accounts are consumed but NOT
                    // emitted — that keeps their markers from piling up while still
                    // never notifying for an account the user turned off.
                    if let event = parse(
                        file: file, accountKey: accountKey, capturedAt: mod ?? now)
                    {
                        if !isDisabled { events.append(event) }
                        try? fm.removeItem(at: file)
                    }
                } else {
                    try? fm.removeItem(at: file)  // definitively stale → clean up
                }
            }
        }
        return events
    }

    /// Removes all attention markers — used when the feature is disabled (the hook's
    /// `mkdir -p` created the dir and nothing drains it once the watcher stops).
    public static func clearAll() {
        try? FileManager.default.removeItem(at: HookBridge.eventsDir)
    }

    static func parse(file: URL, accountKey: String, capturedAt: Date) -> SessionEvent? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let kind = SessionEvent.Kind(from: json["hook_event_name"] as? String)
        let cwd = (json["cwd"] as? String) ?? ((json["workspace"] as? [String: Any])?["current_dir"]
            as? String)
        return SessionEvent(
            kind: kind,
            accountKey: accountKey,
            sessionId: json["session_id"] as? String,
            cwd: cwd,
            message: json["message"] as? String,
            capturedAt: capturedAt
        )
    }
}

extension SessionEvent.Kind {
    fileprivate init(from raw: String?) {
        switch raw {
        case "Stop": self = .stop
        case "Notification": self = .notification
        default: self = .other
        }
    }
}

import ClaudeMeterCore
import Foundation

/// Enough launch-time terminal context to return the user to the terminal that
/// emitted a Claude Code hook. The route is deliberately small and contains no
/// command text or transcript content.
public struct TerminalRoute: Sendable, Equatable {
    public enum Client: String, Sendable {
        case ghostty
        case terminal
        case iTerm2
        case wezTerm
        case warp
    }

    public let client: Client
    /// Controlling TTY as reported by `ps` (for example `ttys003`).
    public let tty: String?
    /// Client-specific locator. Currently this is a WezTerm pane id.
    public let identifier: String?

    public init(client: Client, tty: String?, identifier: String?) {
        self.client = client
        self.tty = tty?.nilIfEmpty
        self.identifier = identifier?.nilIfEmpty
    }

    public init?(termProgram: String, tty: String?, identifier: String?) {
        let client: Client
        switch termProgram.lowercased() {
        case "ghostty": client = .ghostty
        case "apple_terminal": client = .terminal
        case "iterm.app", "iterm2": client = .iTerm2
        case "wezterm": client = .wezTerm
        case "warpterminal", "warp": client = .warp
        default: return nil
        }
        self.init(client: client, tty: tty, identifier: identifier)
    }

    /// AppleScript terminal APIs expose the full device path.
    public var deviceTTY: String? {
        guard let tty else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    /// Reads the compact base64url route suffix written into a hook marker name.
    fileprivate init?(markerFilename: String) {
        let stem = URL(fileURLWithPath: markerFilename).deletingPathExtension().lastPathComponent
        guard let component = stem.split(separator: ".").last,
            component.hasPrefix("cmr-")
        else { return nil }

        guard let data = Base64URL.decode(String(component.dropFirst(4))),
            let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let fields = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let program = fields.first else { return nil }
        self.init(
            termProgram: String(program),
            tty: fields.count > 1 ? String(fields[1]) : nil,
            identifier: fields.count > 2 ? String(fields[2]) : nil
        )
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// One attention event emitted by a Claude Code hook (see `HookBridge`): the agent
/// finished a turn (`Stop`), needs the user (`Notification`), or a turn died on an
/// API error (`StopFailure` — e.g. a rate-limit block). Parsed from a marker file
/// under `~/.claude-meter/events/<accountKey>/<session_id>.<event>.json`.
public struct SessionEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case stop = "Stop"
        case notification = "Notification"
        case stopFailure = "StopFailure"
        case other = "other"
    }

    public let kind: Kind
    /// Config-dir account key the event came from (the marker's subdirectory).
    public let accountKey: String
    public let sessionId: String?
    /// Present only when Claude Code fired the hook from inside a subagent call.
    public let agentId: String?
    /// Working directory of the session — the project the user was in.
    public let cwd: String?
    /// `Notification` message text (e.g. "Claude needs your permission to use Bash").
    public let message: String?
    /// `StopFailure` error classification (e.g. `rate_limit`, `overloaded`, `billing_error`).
    public let errorType: String?
    /// Terminal route captured by the hook, when Claude Code ran in a supported client.
    public let terminalRoute: TerminalRoute?
    /// File modification time — when the hook fired.
    public let capturedAt: Date

    public init(
        kind: Kind, accountKey: String, sessionId: String?, agentId: String? = nil, cwd: String?,
        message: String?,
        errorType: String? = nil, terminalRoute: TerminalRoute? = nil, capturedAt: Date
    ) {
        self.kind = kind
        self.accountKey = accountKey
        self.sessionId = sessionId
        self.agentId = agentId
        self.cwd = cwd
        self.message = message
        self.errorType = errorType
        self.terminalRoute = terminalRoute
        self.capturedAt = capturedAt
    }

    /// API errors that mean the user's own account was *blocked* (quota/payment) —
    /// the only `StopFailure` cases worth alerting on, since claude-meter is a
    /// rate-limit meter. Excludes `overloaded` (server-side 529, not a user limit)
    /// and everything else (auth, invalid request, server error) as noise.
    public static let blockingErrorTypes: Set<String> = ["rate_limit", "billing_error"]

    /// True for a `StopFailure` whose error means the user hit a limit/billing block.
    public var isLimitBlock: Bool {
        kind == .stopFailure && errorType.map(SessionEvent.blockingErrorTypes.contains) == true
    }

    /// Claude Code includes `agent_id` only for hooks fired inside a subagent call.
    public var isSubagent: Bool {
        agentId?.isEmpty == false
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
                let age = mod.map { now.timeIntervalSince($0) }
                // Unknown mtime → treat as fresh for *emitting* (don't drop a real
                // event to a stat blip). capturedAt uses the file mtime when known so
                // the notification id is stable across drains.
                let isFresh = age.map { $0 < maxAge } ?? true
                if let event = parse(file: file, accountKey: accountKey, capturedAt: mod ?? now) {
                    // A subagent finishing is not the end of the user's turn. Consume
                    // its marker without emitting a pointless "your turn" alert. Keep
                    // other subagent events: permission prompts and limit blocks still
                    // need the user's attention.
                    let isNoisySubagentStop = event.kind == .stop && event.isSubagent
                    // Disabled accounts and noisy subagent stops are consumed but NOT
                    // emitted, so their markers cannot pile up.
                    if isFresh, !isDisabled, !isNoisySubagentStop { events.append(event) }
                    try? fm.removeItem(at: file)  // consume on success
                } else {
                    // Parse failed: retry only a genuinely-fresh, known-mtime marker
                    // (a transient mid-write read). A stale OR unknown-mtime failure is
                    // cleaned up so a permanently-corrupt marker can't loop forever.
                    let retain = (age.map { $0 < maxAge }) == true
                    if !retain { try? fm.removeItem(at: file) }
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
            agentId: json["agent_id"] as? String,
            cwd: cwd,
            message: json["message"] as? String,
            errorType: json["error_type"] as? String,
            terminalRoute: TerminalRoute(markerFilename: file.lastPathComponent),
            capturedAt: capturedAt
        )
    }
}

extension SessionEvent.Kind {
    fileprivate init(from raw: String?) {
        switch raw {
        case "Stop": self = .stop
        case "Notification": self = .notification
        case "StopFailure": self = .stopFailure
        default: self = .other
        }
    }
}

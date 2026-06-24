import Foundation

/// Manages the Claude Code statusline bridge.
///
/// Claude Code sends a rich JSON payload to the `statusLine.command` in
/// `~/.claude/settings.json` via stdin on every API call. The bridge snippet
/// captures this data atomically to per-session files under
/// `~/.claude-meter/sessions/` without disrupting any existing statusline command.
public enum StatuslineBridge: Sendable {

    // MARK: - Paths

    static let dataDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-meter")

    /// Per-session payloads live here, one file per Claude Code `session_id`.
    /// Multiple concurrent sessions each write their own file so they no longer
    /// clobber a single shared file (which caused the meter to flip between
    /// sessions' rate-limit snapshots).
    static let sessionsDir: URL =
        dataDir
        .appendingPathComponent("sessions")

    /// Legacy single-file path written by pre-multisession installs. Still read
    /// during migration; new installs write into `sessionsDir`.
    public static let statuslineFilePath: URL =
        dataDir
        .appendingPathComponent("statusline.json")

    private static let claudeSettingsPath: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    // MARK: - Bridge snippet

    /// Re-run the statusline command every second while Claude Code is open (minimum allowed).
    private static let refreshIntervalSeconds = 1

    /// Inline bash snippet: reads stdin, extracts `session_id`, and atomically
    /// writes the payload to `~/.claude-meter/sessions/<session_id>.json`, then
    /// pipes stdin through to the next command unchanged.
    static let bridgeSnippet =
        #"bash -c 'I=$(cat);D=$HOME/.claude-meter/sessions;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#

    /// Snippets from earlier app versions; recognised so `install()` can migrate
    /// them to the current snippet and `uninstall()` can remove them cleanly.
    static let legacyBridgeSnippets: [String] = [
        #"bash -c 'I=$(cat);D=$HOME/.claude-meter;mkdir -p "$D" 2>/dev/null;T="$D/.sl-$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/statusline.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#
    ]

    private static var allBridgeSnippets: [String] { [bridgeSnippet] + legacyBridgeSnippets }

    // MARK: - Install / uninstall

    /// Installs the bridge snippet into `~/.claude/settings.json` and sets `refreshInterval` to 1.
    /// Idempotent — safe to call on every app launch.
    public static func install() throws {
        guard
            FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude").path
            )
        else { return }

        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        var settings = try readSettings()
        var needsWrite = false

        // Strip any bridge variant (current or legacy) to recover the user's own
        // command, then prepend the current snippet. This migrates old installs.
        let currentCmd = statusLineCommand(in: settings)
        let userCmd = strippedOfAnyBridge(from: currentCmd)
        let desiredCmd =
            userCmd.isEmpty
            ? bridgeSnippet + " > /dev/null"
            : bridgeSnippet + " | " + userCmd
        if currentCmd != desiredCmd {
            upsertStatusLine(command: desiredCmd, in: &settings)
            needsWrite = true
        }
        if ensureRefreshInterval(in: &settings) {
            needsWrite = true
        }

        if needsWrite {
            try writeSettings(settings)
        }
    }

    /// Removes the bridge snippet from `~/.claude/settings.json`.
    public static func uninstall() throws {
        var settings = try readSettings()
        let currentCmd = statusLineCommand(in: settings)
        let restored = strippedOfAnyBridge(from: currentCmd)
        guard restored != currentCmd else { return }

        if restored.isEmpty {
            settings.removeValue(forKey: "statusLine")
        } else {
            setStatusLineCommand(restored, in: &settings)
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: sessionsDir)
        try? FileManager.default.removeItem(at: statuslineFilePath)
    }

    // MARK: - Freshness check

    /// Returns true if any session payload (or the legacy file) was modified
    /// within `maxAge` seconds — i.e. at least one Claude Code session is active.
    public static func isDataFresh(maxAge: TimeInterval = 300) -> Bool {
        !freshPayloadFiles(maxAge: maxAge).isEmpty
    }

    /// All payload files modified within `maxAge` seconds: per-session files plus
    /// the legacy single file (present only on not-yet-migrated installs).
    private static func freshPayloadFiles(maxAge: TimeInterval, now: Date = Date()) -> [URL] {
        var urls: [URL] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: keys
        ) {
            for url in entries where url.pathExtension == "json" {
                if let mod = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate,
                    now.timeIntervalSince(mod) < maxAge
                {
                    urls.append(url)
                }
            }
        }
        if let mod =
            (try? FileManager.default.attributesOfItem(
                atPath: statuslineFilePath.path))?[.modificationDate] as? Date,
            now.timeIntervalSince(mod) < maxAge
        {
            urls.append(statuslineFilePath)
        }
        return urls
    }

    // MARK: - Data model

    public struct RateLimitWindow: Sendable {
        public let usedPercentage: Double
        public let resetsAt: Date?
    }

    public struct StatuslinePayload: Sendable {
        public let fiveHour: RateLimitWindow?
        public let sevenDay: RateLimitWindow?
        public let sevenDayOpus: RateLimitWindow?
        public let sessionId: String?
        public let sessionName: String?
        public let cwd: String?
        public let modelId: String?
        public let modelDisplayName: String?
        public let totalCostUsd: Double?
        public let totalApiDurationMs: Double?
        public let codeLinesAdded: Int?
        public let codeLinesRemoved: Int?
        public let cliVersion: String?
        public let capturedAt: Date

        public init(
            fiveHour: RateLimitWindow?,
            sevenDay: RateLimitWindow?,
            sevenDayOpus: RateLimitWindow? = nil,
            sessionId: String?,
            sessionName: String?,
            cwd: String?,
            modelId: String?,
            modelDisplayName: String?,
            totalCostUsd: Double?,
            totalApiDurationMs: Double?,
            codeLinesAdded: Int?,
            codeLinesRemoved: Int?,
            cliVersion: String?,
            capturedAt: Date
        ) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.sevenDayOpus = sevenDayOpus
            self.sessionId = sessionId
            self.sessionName = sessionName
            self.cwd = cwd
            self.modelId = modelId
            self.modelDisplayName = modelDisplayName
            self.totalCostUsd = totalCostUsd
            self.totalApiDurationMs = totalApiDurationMs
            self.codeLinesAdded = codeLinesAdded
            self.codeLinesRemoved = codeLinesRemoved
            self.cliVersion = cliVersion
            self.capturedAt = capturedAt
        }
    }

    // MARK: - Read data

    /// Reads and merges payloads from every active Claude Code session.
    ///
    /// Each session caches the rate-limit state from *its* last API call, so
    /// concurrent sessions report different snapshots of varying staleness. We
    /// merge by recency: the five-hour window with the latest `resets_at` is the
    /// most recent observation, and weekly usage only grows so the highest value
    /// is freshest. Returns nil when no fresh payload exists.
    public static func readData(maxAge: TimeInterval = 300) throws -> StatuslinePayload? {
        let payloads = freshPayloadFiles(maxAge: maxAge)
            .compactMap { try? readPayload(from: $0) }
            .compactMap { $0 }
        return mergePayloads(payloads)
    }

    /// Merges per-session payloads into a single coherent reading. Account-wide
    /// windows are picked by observation recency; session metadata comes from the
    /// most recently written file. Returns nil for an empty input.
    static func mergePayloads(_ payloads: [StatuslinePayload]) -> StatuslinePayload? {
        guard let base = payloads.max(by: { $0.capturedAt < $1.capturedAt }) else { return nil }

        let fiveHour = payloads.compactMap(\.fiveHour).max { a, b in
            let ra = a.resetsAt ?? .distantPast
            let rb = b.resetsAt ?? .distantPast
            if ra != rb { return ra < rb }
            return a.usedPercentage < b.usedPercentage
        }
        let sevenDay = payloads.compactMap(\.sevenDay).max { a, b in
            let ra = a.resetsAt ?? .distantPast
            let rb = b.resetsAt ?? .distantPast
            if ra != rb { return ra < rb }
            return a.usedPercentage < b.usedPercentage
        }
        let sevenDayOpus = payloads.compactMap(\.sevenDayOpus).max { a, b in
            let ra = a.resetsAt ?? .distantPast
            let rb = b.resetsAt ?? .distantPast
            if ra != rb { return ra < rb }
            return a.usedPercentage < b.usedPercentage
        }

        return StatuslinePayload(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: sevenDayOpus,
            sessionId: base.sessionId,
            sessionName: base.sessionName,
            cwd: base.cwd,
            modelId: base.modelId,
            modelDisplayName: base.modelDisplayName,
            totalCostUsd: base.totalCostUsd,
            totalApiDurationMs: base.totalApiDurationMs,
            codeLinesAdded: base.codeLinesAdded,
            codeLinesRemoved: base.codeLinesRemoved,
            cliVersion: base.cliVersion,
            capturedAt: base.capturedAt
        )
    }

    internal static func readPayload(from statuslineFilePath: URL) throws -> StatuslinePayload? {
        guard
            let modDate =
                (try? FileManager.default.attributesOfItem(
                    atPath: statuslineFilePath.path))?[.modificationDate] as? Date
        else { return nil }

        let raw = try Data(contentsOf: statuslineFilePath)
        guard !raw.isEmpty,
            let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }

        let rateLimits = json["rate_limits"] as? [String: Any]

        func window(_ key: String) -> RateLimitWindow? {
            guard let obj = rateLimits?[key] as? [String: Any],
                let pct = numericValue(obj["used_percentage"])
            else { return nil }
            let resetsAt = numericValue(obj["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            return RateLimitWindow(usedPercentage: pct, resetsAt: resetsAt)
        }

        let model = json["model"] as? [String: Any]
        let cost = json["cost"] as? [String: Any]
        let workspace = json["workspace"] as? [String: Any]
        let cwd = (workspace?["current_dir"] as? String) ?? (json["cwd"] as? String)

        return StatuslinePayload(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            sevenDayOpus: window("seven_day_opus"),
            sessionId: json["session_id"] as? String,
            sessionName: json["session_name"] as? String,
            cwd: cwd,
            modelId: model?["id"] as? String,
            modelDisplayName: model?["display_name"] as? String,
            totalCostUsd: numericValue(cost?["total_cost_usd"]),
            totalApiDurationMs: numericValue(cost?["total_api_duration_ms"]),
            codeLinesAdded: numericValue(cost?["total_lines_added"]).map { Int($0) },
            codeLinesRemoved: numericValue(cost?["total_lines_removed"]).map { Int($0) },
            cliVersion: json["version"] as? String,
            capturedAt: modDate
        )
    }

    // MARK: - Settings helpers

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: claudeSettingsPath.path) else { return [:] }
        return try parseSettingsData(Data(contentsOf: claudeSettingsPath))
    }

    internal static func parseSettingsDataForTesting(_ data: Data?) throws -> [String: Any] {
        try parseSettingsData(data)
    }

    private static func parseSettingsData(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !data.isEmpty else { throw StatuslineBridgeError.invalidSettingsJSON }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StatuslineBridgeError.invalidSettingsJSON
        }
        guard let settings = object as? [String: Any] else {
            throw StatuslineBridgeError.settingsRootNotObject
        }
        return settings
    }

    private static func statusLineCommand(in settings: [String: Any]) -> String {
        (settings["statusLine"] as? [String: Any])?["command"] as? String ?? ""
    }

    private static func upsertStatusLine(command: String, in settings: inout [String: Any]) {
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = command
        statusLine["refreshInterval"] = refreshIntervalSeconds
        settings["statusLine"] = statusLine
    }

    /// Ensures `refreshInterval` is set. Returns true when settings were modified.
    @discardableResult
    internal static func ensureRefreshInterval(in settings: inout [String: Any]) -> Bool {
        guard var statusLine = settings["statusLine"] as? [String: Any],
            statusLine["command"] != nil
        else { return false }
        let current =
            (statusLine["refreshInterval"] as? Int)
            ?? (statusLine["refreshInterval"] as? Double).map { Int($0) }
        guard current != refreshIntervalSeconds else { return false }
        statusLine["refreshInterval"] = refreshIntervalSeconds
        settings["statusLine"] = statusLine
        return true
    }

    private static func setStatusLineCommand(_ cmd: String, in settings: inout [String: Any]) {
        upsertStatusLine(command: cmd, in: &settings)
    }

    /// Removes every leading bridge snippet (current or legacy) from `command`,
    /// returning the user's original command (empty if the bridge was the whole
    /// command). Loops to collapse chains of duplicates that earlier versions
    /// could accumulate. Returns `command` unchanged when no bridge is present.
    static func strippedOfAnyBridge(from command: String) -> String {
        var cmd = command
        while true {
            var didStrip = false
            for snippet in allBridgeSnippets {
                let pipePrefix = snippet + " | "
                if cmd.hasPrefix(pipePrefix) {
                    cmd = String(cmd.dropFirst(pipePrefix.count))
                    didStrip = true
                    break
                }
                if cmd == snippet + " > /dev/null" || cmd == snippet {
                    return ""
                }
            }
            if !didStrip { return cmd }
        }
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        let dir = claudeSettingsPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: claudeSettingsPath, options: .atomic)
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }
}

private enum StatuslineBridgeError: Error, LocalizedError {
    case invalidSettingsJSON
    case settingsRootNotObject

    var errorDescription: String? {
        switch self {
        case .invalidSettingsJSON:
            "Claude Code settings.json is not valid JSON; statusline bridge was not installed."
        case .settingsRootNotObject:
            "Claude Code settings.json must contain a JSON object; statusline bridge was not installed."
        }
    }
}

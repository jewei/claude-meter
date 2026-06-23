import Foundation

/// Manages the Claude Code statusline bridge.
///
/// Claude Code sends a rich JSON payload to the `statusLine.command` in
/// `~/.claude/settings.json` via stdin on every API call. The bridge snippet
/// captures this data atomically to `~/.claude-meter/statusline.json` without
/// disrupting any existing statusline command.
public enum StatuslineBridge: Sendable {

    // MARK: - Paths

    static let dataDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-meter")

    public static let statuslineFilePath: URL = dataDir
        .appendingPathComponent("statusline.json")

    private static let claudeSettingsPath: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    // MARK: - Bridge snippet

    /// Unique substring used to detect if our bridge is already installed.
    private static let bridgeMarker = ".claude-meter/statusline.json"

    /// Re-run the statusline command every second while Claude Code is open (minimum allowed).
    private static let refreshIntervalSeconds = 1

    /// Inline bash snippet: reads stdin, saves atomically, pipes through to next command.
    private static let bridgeSnippet = #"bash -c 'I=$(cat);D=$HOME/.claude-meter;mkdir -p "$D" 2>/dev/null;T="$D/.sl-$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/statusline.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#

    // MARK: - Install / uninstall

    /// Installs the bridge snippet into `~/.claude/settings.json` and sets `refreshInterval` to 1.
    /// Idempotent — safe to call on every app launch.
    public static func install() throws {
        guard FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude").path
        ) else { return }

        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        var settings = try readSettings()
        var needsWrite = false

        let currentCmd = statusLineCommand(in: settings)
        if !currentCmd.contains(bridgeMarker) {
            let newCmd = currentCmd.isEmpty
                ? bridgeSnippet + " > /dev/null"
                : bridgeSnippet + " | " + currentCmd
            upsertStatusLine(command: newCmd, in: &settings)
            needsWrite = true
        } else if ensureRefreshInterval(in: &settings) {
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
        guard currentCmd.contains(bridgeMarker) else { return }

        let restored = removedBridgeSnippet(from: currentCmd)
        if restored.isEmpty {
            settings.removeValue(forKey: "statusLine")
        } else {
            setStatusLineCommand(restored, in: &settings)
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: statuslineFilePath)
    }

    // MARK: - Freshness check

    /// Returns true if the statusline file exists and was modified within `maxAge` seconds.
    public static func isDataFresh(maxAge: TimeInterval = 300) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: statuslineFilePath.path),
              let modDate = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modDate) < maxAge
    }

    // MARK: - Data model

    public struct RateLimitWindow: Sendable {
        public let usedPercentage: Double
        public let resetsAt: Date?
    }

    public struct StatuslinePayload: Sendable {
        public let fiveHour: RateLimitWindow?
        public let sevenDay: RateLimitWindow?
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
    }

    // MARK: - Read data

    /// Reads and parses the statusline payload from `~/.claude-meter/statusline.json`.
    /// Returns nil if the file doesn't exist; throws on parse failure.
    public static func readData() throws -> StatuslinePayload? {
        guard let modDate = (try? FileManager.default.attributesOfItem(
            atPath: statuslineFilePath.path))?[.modificationDate] as? Date
        else { return nil }

        let raw = try Data(contentsOf: statuslineFilePath)
        guard !raw.isEmpty,
              let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }

        let rateLimits = json["rate_limits"] as? [String: Any]

        func window(_ key: String) -> RateLimitWindow? {
            guard let obj = rateLimits?[key] as? [String: Any],
                  let pct = obj["used_percentage"] as? Double else { return nil }
            let resetsAt = (obj["resets_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            return RateLimitWindow(usedPercentage: pct, resetsAt: resetsAt)
        }

        let model = json["model"] as? [String: Any]
        let cost = json["cost"] as? [String: Any]
        let workspace = json["workspace"] as? [String: Any]
        let cwd = (workspace?["current_dir"] as? String) ?? (json["cwd"] as? String)

        return StatuslinePayload(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            sessionId: json["session_id"] as? String,
            sessionName: json["session_name"] as? String,
            cwd: cwd,
            modelId: model?["id"] as? String,
            modelDisplayName: model?["display_name"] as? String,
            totalCostUsd: cost?["total_cost_usd"] as? Double,
            totalApiDurationMs: cost?["total_api_duration_ms"] as? Double,
            codeLinesAdded: cost?["total_lines_added"].flatMap { $0 as? Int },
            codeLinesRemoved: cost?["total_lines_removed"].flatMap { $0 as? Int },
            cliVersion: json["version"] as? String,
            capturedAt: modDate
        )
    }

    // MARK: - Settings helpers

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeSettingsPath) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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
              statusLine["command"] != nil else { return false }
        let current = (statusLine["refreshInterval"] as? Int)
            ?? (statusLine["refreshInterval"] as? Double).map { Int($0) }
        guard current != refreshIntervalSeconds else { return false }
        statusLine["refreshInterval"] = refreshIntervalSeconds
        settings["statusLine"] = statusLine
        return true
    }

    private static func setStatusLineCommand(_ cmd: String, in settings: inout [String: Any]) {
        upsertStatusLine(command: cmd, in: &settings)
    }

    private static func removedBridgeSnippet(from command: String) -> String {
        let pipePrefix = bridgeSnippet + " | "
        if command.hasPrefix(pipePrefix) { return String(command.dropFirst(pipePrefix.count)) }
        if command == bridgeSnippet + " > /dev/null" { return "" }
        return command
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        let dir = claudeSettingsPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: claudeSettingsPath, options: .atomic)
    }
}

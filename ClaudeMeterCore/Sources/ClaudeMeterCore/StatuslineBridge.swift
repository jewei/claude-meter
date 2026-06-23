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
        try readData(from: statuslineFilePath)
    }

    internal static func readData(from statuslineFilePath: URL) throws -> StatuslinePayload? {
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
                  let pct = numericValue(obj["used_percentage"]) else { return nil }
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

import ClaudeMeterCore
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

    /// Per-account session payloads live under `sessions/<accountKey>/<session_id>.json`.
    /// Each Claude Code window writes its own file (so concurrent sessions don't
    /// clobber each other), and the account subdir keeps separate accounts'
    /// rate-limit snapshots from ever being merged together.
    static let sessionsDir: URL =
        dataDir
        .appendingPathComponent("sessions")

    /// The per-account subdirectory holding one account's session files.
    static func sessionsDir(for accountKey: String) -> URL {
        sessionsDir.appendingPathComponent(accountKey)
    }

    /// Legacy single-file path written by the earliest installs. Still read during
    /// migration (bucketed under the default `claude` account); new installs write
    /// into `sessionsDir(for:)`.
    public static let statuslineFilePath: URL =
        dataDir
        .appendingPathComponent("statusline.json")

    /// The default Claude config directory (`~/.claude`).
    static let defaultConfigDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")

    // MARK: - Bridge snippet

    /// Re-run the statusline command every second while Claude Code is open (minimum allowed).
    private static let refreshIntervalSeconds = 1

    /// Inline bash snippet: reads stdin, derives the account key from
    /// `$CLAUDE_CONFIG_DIR` (basename, leading dot stripped, sanitized to
    /// `[:alnum:]._-` — identical to `ConfigDirDiscovery.accountKey`), extracts
    /// `session_id`, and atomically writes the payload to
    /// `~/.claude-meter/sessions/<accountKey>/<session_id>.json`, then pipes stdin
    /// through to the next command unchanged.
    static let bridgeSnippet =
        #"bash -c 'I=$(cat);A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};A=$(printf "%s" "$A"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$A" ]&&A=claude;D=$HOME/.claude-meter/sessions/$A;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|LC_ALL=C tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#

    /// Snippets from earlier app versions; recognised so `install()` can migrate
    /// them to the current snippet and `uninstall()` can remove them cleanly. First
    /// is the pre-account per-session snippet (flat `sessions/<session_id>.json`),
    /// second the original single-file snippet.
    static let legacyBridgeSnippets: [String] = [
        #"bash -c 'I=$(cat);D=$HOME/.claude-meter/sessions;mkdir -p "$D" 2>/dev/null;S=$(printf "%s" "$I"|sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p");S=$(printf "%s" "$S"|tr -cd "[:alnum:]._-");[ -z "$S" ]&&S=default;T="$D/.tmp.$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/$S.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#,
        #"bash -c 'I=$(cat);D=$HOME/.claude-meter;mkdir -p "$D" 2>/dev/null;T="$D/.sl-$$";printf "%s" "$I">"$T"&&mv -f "$T" "$D/statusline.json" 2>/dev/null||rm -f "$T" 2>/dev/null;printf "%s" "$I"'"#,
    ]

    private static var allBridgeSnippets: [String] { [bridgeSnippet] + legacyBridgeSnippets }

    // MARK: - Install / uninstall

    /// Installs the bridge into the default `~/.claude` config dir. Convenience
    /// shim for callers that don't enumerate config dirs.
    public static func install() throws {
        try install(configDirs: [defaultConfigDir])
    }

    /// Installs the bridge snippet into each config dir's `settings.json` and sets
    /// `refreshInterval` to 1. Idempotent — safe to call on every app launch.
    /// Dirs that don't exist are skipped; a dir whose `settings.json` is invalid
    /// JSON is skipped without blocking the others (its error is surfaced after).
    public static func install(configDirs: [URL]) throws {
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)

        var firstError: Error?
        for dir in configDirs {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            do {
                try installOne(settingsPath: dir.appendingPathComponent("settings.json"))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private static func installOne(settingsPath: URL) throws {
        var settings = try readSettings(at: settingsPath)
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
            try writeSettings(settings, at: settingsPath)
        }
    }

    /// Removes the bridge from the default `~/.claude` config dir.
    public static func uninstall() throws {
        try uninstall(configDirs: [defaultConfigDir])
    }

    /// Removes the bridge snippet from each config dir's `settings.json` and
    /// deletes the per-session data directory.
    public static func uninstall(configDirs: [URL]) throws {
        var firstError: Error?
        for dir in configDirs {
            let settingsPath = dir.appendingPathComponent("settings.json")
            guard FileManager.default.fileExists(atPath: settingsPath.path) else { continue }
            do {
                try uninstallOne(settingsPath: settingsPath)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        try? FileManager.default.removeItem(at: sessionsDir)
        try? FileManager.default.removeItem(at: statuslineFilePath)
        if let firstError { throw firstError }
    }

    private static func uninstallOne(settingsPath: URL) throws {
        var settings = try readSettings(at: settingsPath)
        let currentCmd = statusLineCommand(in: settings)
        let restored = strippedOfAnyBridge(from: currentCmd)
        guard restored != currentCmd else { return }

        if restored.isEmpty {
            settings.removeValue(forKey: "statusLine")
        } else {
            setStatusLineCommand(restored, in: &settings)
        }
        try writeSettings(settings, at: settingsPath)
    }

    // MARK: - Freshness check

    /// Returns true if any account's session payload (or a legacy file) was
    /// modified within `maxAge` seconds — i.e. at least one Claude Code session is
    /// active across any account.
    public static func isDataFresh(maxAge: TimeInterval = 300) -> Bool {
        let fm = FileManager.default
        let now = Date()
        // Any legacy flat files directly under sessionsDir.
        if anyFreshJSON(in: sessionsDir, maxAge: maxAge, now: now) { return true }
        // Per-account subdirs.
        if let subdirs = try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for sub in subdirs where isDirectory(sub) {
                if anyFreshJSON(in: sub, maxAge: maxAge, now: now) { return true }
            }
        }
        // Legacy single statusline.json.
        if let mod =
            (try? fm.attributesOfItem(atPath: statuslineFilePath.path))?[.modificationDate]
                as? Date,
            now.timeIntervalSince(mod) < maxAge
        {
            return true
        }
        return false
    }

    /// True when `dir` directly contains at least one `*.json` modified within `maxAge`.
    private static func anyFreshJSON(in dir: URL, maxAge: TimeInterval, now: Date) -> Bool {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return false }
        for url in entries where url.pathExtension == "json" {
            if let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
                now.timeIntervalSince(mod) < maxAge
            {
                return true
            }
        }
        return false
    }

    /// Fresh payloads (`*.json` within `maxAge`) directly inside `dir`, parsed.
    private static func freshPayloads(in dir: URL, maxAge: TimeInterval, now: Date = Date())
        -> [StatuslinePayload]
    {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return [] }
        var out: [StatuslinePayload] = []
        for url in entries where url.pathExtension == "json" {
            guard
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate,
                now.timeIntervalSince(mod) < maxAge
            else { continue }
            if let payload = try? readPayload(from: url) { out.append(payload) }
        }
        return out
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
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

    /// Reads and merges per-account payloads, keyed by account key.
    ///
    /// Each Claude Code window caches the rate-limit state from *its* last API call,
    /// so concurrent sessions report snapshots of varying staleness. Within an
    /// account we merge by recency (latest `resets_at` wins); we never merge across
    /// accounts, since their rate-limit buckets are independent. Legacy flat files
    /// and the legacy single file are bucketed under the default `claude` account.
    /// Returns an empty dictionary when no fresh payload exists.
    public static func readDataGrouped(maxAge: TimeInterval = 300) -> [String: StatuslinePayload] {
        readDataGrouped(sessionsRoot: sessionsDir, legacyFile: statuslineFilePath, maxAge: maxAge)
    }

    /// Testable core of `readDataGrouped` with injectable paths.
    static func readDataGrouped(
        sessionsRoot: URL, legacyFile: URL?, maxAge: TimeInterval
    ) -> [String: StatuslinePayload] {
        var groups: [String: [StatuslinePayload]] = [:]
        let fm = FileManager.default

        // Per-account subdirs (subdir name == account key).
        if let subdirs = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for sub in subdirs where isDirectory(sub) {
                let payloads = freshPayloads(in: sub, maxAge: maxAge)
                if !payloads.isEmpty { groups[sub.lastPathComponent, default: []] += payloads }
            }
        }

        // Legacy flat files written by the pre-account snippet → default account.
        // (`freshPayloads(in:)` only matches `*.json`, so subdirs are skipped.)
        let legacyFlat = freshPayloads(in: sessionsRoot, maxAge: maxAge)
        if !legacyFlat.isEmpty { groups[defaultAccountKey, default: []] += legacyFlat }

        // Legacy single statusline.json → default account.
        if let legacyFile, let legacy = freshPayloadFile(legacyFile, maxAge: maxAge) {
            groups[defaultAccountKey, default: []].append(legacy)
        }

        var merged: [String: StatuslinePayload] = [:]
        for (key, payloads) in groups {
            if let m = mergePayloads(payloads) { merged[key] = m }
        }
        return merged
    }

    /// Recency proxy for an account's merged payload: the latest window reset we've
    /// observed (five-hour preferred, then weekly), falling back to capture time.
    /// Each real use pushes the five-hour window's reset forward, so this tracks
    /// "most recently used" better than file mtime (idle sessions re-emit stale data).
    static func payloadRecency(_ payload: StatuslinePayload) -> Date {
        [payload.fiveHour?.resetsAt, payload.sevenDay?.resetsAt]
            .compactMap { $0 }
            .max() ?? payload.capturedAt
    }

    /// Account key the default `~/.claude` config dir (and legacy pre-account
    /// files) are bucketed under.
    public static let defaultAccountKey = "claude"

    private static func freshPayloadFile(_ url: URL, maxAge: TimeInterval, now: Date = Date())
        -> StatuslinePayload?
    {
        guard
            let mod =
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                as? Date,
            now.timeIntervalSince(mod) < maxAge
        else { return nil }
        return try? readPayload(from: url)
    }

    /// Merges per-session payloads into a single coherent reading. Account-wide
    /// windows are picked by observation recency; session metadata comes from the
    /// most recently written file. Returns nil for an empty input.
    /// Picks the window observed most recently (latest `resets_at`, breaking ties
    /// by higher used %), since rate-limit buckets are independent per account.
    private static func mostRecentWindow(_ windows: [RateLimitWindow]) -> RateLimitWindow? {
        windows.max { a, b in
            let ra = a.resetsAt ?? .distantPast
            let rb = b.resetsAt ?? .distantPast
            if ra != rb { return ra < rb }
            return a.usedPercentage < b.usedPercentage
        }
    }

    static func mergePayloads(_ payloads: [StatuslinePayload]) -> StatuslinePayload? {
        guard let base = payloads.max(by: { $0.capturedAt < $1.capturedAt }) else { return nil }

        let fiveHour = mostRecentWindow(payloads.compactMap(\.fiveHour))
        let sevenDay = mostRecentWindow(payloads.compactMap(\.sevenDay))
        let sevenDayOpus = mostRecentWindow(payloads.compactMap(\.sevenDayOpus))

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

    private static func readSettings(at settingsPath: URL) throws -> [String: Any] {
        try SettingsFile.read(at: settingsPath)
    }

    internal static func parseSettingsDataForTesting(_ data: Data?) throws -> [String: Any] {
        try SettingsFile.parse(data)
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

    private static func writeSettings(_ settings: [String: Any], at settingsPath: URL) throws {
        try SettingsFile.write(settings, at: settingsPath)
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


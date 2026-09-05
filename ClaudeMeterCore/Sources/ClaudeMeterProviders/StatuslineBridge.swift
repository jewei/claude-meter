import ClaudeMeterCore
import Darwin
import Foundation

/// Manages the Claude Code statusline bridge.
///
/// Claude Code sends a rich JSON payload to the `statusLine.command` in
/// `~/.claude/settings.json` via stdin on every API call. The bridge snippet
/// captures this data atomically to per-session files under
/// `~/.claude-meter/sessions/` without disrupting any existing statusline command.
public enum StatuslineBridge: Sendable {
    /// Statusline payloads are small. Reject a file that is too large instead of
    /// allocating memory from an untrusted session entry.
    private static let maximumPayloadBytes = 1_048_576
    /// Permit normal clock skew, but reject a payload dated far into the future.
    private static let maximumFutureClockSkew: TimeInterval = 300

    /// Reports that a best-effort batch uninstall changed at least one valid
    /// settings file before another settings file failed.
    public struct UninstallError: Error, LocalizedError, Sendable {
        public let didChange: Bool
        private let message: String

        init(didChange: Bool, underlyingError: Error) {
            self.didChange = didChange
            self.message =
                (underlyingError as? LocalizedError)?.errorDescription
                ?? underlyingError.localizedDescription
        }

        public var errorDescription: String? { message }
    }

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
        try ensureDirectory(at: sessionsDir)

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

    static func ensureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func installOne(settingsPath: URL) throws {
        var settings = try SettingsFile.read(at: settingsPath)
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
            try SettingsFile.write(settings, at: settingsPath)
        }
    }

    /// Removes the bridge from the default `~/.claude` config dir.
    public static func uninstall() throws {
        try uninstall(configDirs: [defaultConfigDir])
    }

    /// Removes the bridge snippet from each config dir's `settings.json`, returning
    /// whether anything changed. Idempotent: a second call over already-clean dirs
    /// writes nothing and returns `false`, so this is safe to run on every reconcile.
    ///
    /// Touches only the given config dirs. Purging the captured session data is a
    /// separate, explicit step (`purgeSessionData`) — exactly like `HookBridge`,
    /// and for the same reason: it keeps this operation off the real
    /// `~/.claude-meter` when called from tests.
    @discardableResult
    public static func uninstall(configDirs: [URL]) throws -> Bool {
        var firstError: Error?
        var didChange = false
        for dir in configDirs {
            let settingsPath = dir.appendingPathComponent("settings.json")
            guard FileManager.default.fileExists(atPath: settingsPath.path) else { continue }
            do {
                if try uninstallOne(settingsPath: settingsPath) { didChange = true }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw UninstallError(didChange: didChange, underlyingError: firstError)
        }
        return didChange
    }

    /// Deletes the captured session payloads. Call only from the app, after
    /// `uninstall` reports that a snippet was actually removed.
    public static func purgeSessionData() {
        purgeSessionData(dataRoot: dataDir)
    }

    /// Testable cleanup that never resolves a recursive delete through a linked
    /// `.claude-meter` directory. Empty directories can remain; the data files are
    /// the state that must be removed.
    static func purgeSessionData(
        dataRoot dataRootURL: URL,
        beforeUnlink: ((String, String) -> Void)? = nil
    ) {
        guard
            let dataRoot = try? BoundedRegularFileReader.AnchoredDirectory(
                opening: dataRootURL)
        else { return }
        clearManagedSubdirectory(
            named: "sessions",
            in: dataRoot,
            dataRootURL: dataRootURL,
            beforeUnlink: beforeUnlink)
        clearManagedFile(
            named: "statusline.json", in: dataRoot, dataRootURL: dataRootURL)
    }

    /// Clears direct files in one managed directory and in its direct child
    /// directories. Every removal uses the descriptor that inspected the entry.
    /// The full directory chain is rechecked first, so a renamed data tree is left
    /// intact and a replacement link cannot redirect deletion.
    static func clearManagedSubdirectory(
        named childName: String,
        in dataRootURL: URL,
        beforeUnlink: ((String, String) -> Void)? = nil
    ) {
        guard
            let dataRoot = try? BoundedRegularFileReader.AnchoredDirectory(
                opening: dataRootURL)
        else { return }
        clearManagedSubdirectory(
            named: childName,
            in: dataRoot,
            dataRootURL: dataRootURL,
            beforeUnlink: beforeUnlink)
    }

    private static func clearManagedSubdirectory(
        named childName: String,
        in dataRoot: BoundedRegularFileReader.AnchoredDirectory,
        dataRootURL: URL,
        beforeUnlink: ((String, String) -> Void)?
    ) {
        guard let child = try? dataRoot.directory(named: childName) else { return }

        func baseIsIntact() -> Bool {
            dataRoot.stillNamesDirectory(at: dataRootURL)
                && dataRoot.stillContainsDirectory(child, named: childName)
        }

        for name in (try? child.entryNames()) ?? [] {
            if let account = try? child.directory(named: name) {
                for filename in (try? account.entryNames()) ?? [] {
                    guard let entry = try? account.entry(named: filename) else { continue }
                    beforeUnlink?(name, filename)
                    guard baseIsIntact(), child.stillContainsDirectory(account, named: name)
                    else { continue }
                    account.unlinkEntry(named: filename, ifUnchangedSince: entry)
                }
            } else {
                guard let entry = try? child.entry(named: name) else { continue }
                beforeUnlink?("", name)
                guard baseIsIntact() else { continue }
                child.unlinkEntry(named: name, ifUnchangedSince: entry)
            }
        }
    }

    private static func clearManagedFile(
        named name: String,
        in dataRoot: BoundedRegularFileReader.AnchoredDirectory,
        dataRootURL: URL
    ) {
        guard
            let entry = try? dataRoot.entry(named: name),
            dataRoot.stillNamesDirectory(at: dataRootURL)
        else { return }
        dataRoot.unlinkEntry(named: name, ifUnchangedSince: entry)
    }

    @discardableResult
    private static func uninstallOne(settingsPath: URL) throws -> Bool {
        var settings = try SettingsFile.read(at: settingsPath)
        let currentCmd = statusLineCommand(in: settings)
        let restored = strippedOfAnyBridge(from: currentCmd)
        guard restored != currentCmd else { return false }

        if restored.isEmpty {
            settings.removeValue(forKey: "statusLine")
        } else {
            setStatusLineCommand(restored, in: &settings)
        }
        try SettingsFile.write(settings, at: settingsPath)
        return true
    }

    // MARK: - Freshness check

    /// Returns true if any account's session payload (or a legacy file) was
    /// modified within `maxAge` seconds — i.e. at least one Claude Code session is
    /// active across any account.
    public static func isDataFresh(maxAge: TimeInterval = 300) -> Bool {
        isDataFresh(dataRoot: dataDir, maxAge: maxAge)
    }

    /// Production-path core with an injectable app-data root. Opening the data
    /// root first rejects an intermediate `.claude-meter` link.
    static func isDataFresh(dataRoot dataRootURL: URL, maxAge: TimeInterval) -> Bool {
        guard
            let dataRoot = try? BoundedRegularFileReader.AnchoredDirectory(
                opening: dataRootURL)
        else { return false }
        let now = Date()
        if let sessions = try? dataRoot.directory(named: "sessions"),
            containsFreshPayload(in: sessions, maxAge: maxAge, now: now)
        {
            return true
        }
        return isFreshRegularPayloadFile(
            named: "statusline.json", in: dataRoot, maxAge: maxAge, now: now)
    }

    /// Testable core of `isDataFresh` with injectable paths.
    static func isDataFresh(
        sessionsRoot: URL,
        legacyFile: URL?,
        maxAge: TimeInterval
    ) -> Bool {
        let now = Date()
        if let root = try? BoundedRegularFileReader.AnchoredDirectory(opening: sessionsRoot) {
            if containsFreshPayload(in: root, maxAge: maxAge, now: now) { return true }
        }
        // Legacy single statusline.json.
        if let legacyFile, isFreshRegularPayloadFile(legacyFile, maxAge: maxAge, now: now) {
            return true
        }
        return false
    }

    private static func containsFreshPayload(
        in root: BoundedRegularFileReader.AnchoredDirectory,
        maxAge: TimeInterval,
        now: Date
    ) -> Bool {
        // Any legacy flat files directly under sessionsDir.
        if anyFreshJSON(in: root, maxAge: maxAge, now: now) { return true }
        // Per-account subdirs. Open each child relative to the stable root
        // descriptor so a path replacement cannot redirect the scan.
        for name in (try? root.entryNames()) ?? [] {
            guard let account = try? root.directory(named: name) else { continue }
            if anyFreshJSON(in: account, maxAge: maxAge, now: now) { return true }
        }
        return false
    }

    /// True when `dir` directly contains at least one `*.json` modified within `maxAge`.
    private static func anyFreshJSON(
        in directory: BoundedRegularFileReader.AnchoredDirectory,
        maxAge: TimeInterval,
        now: Date
    ) -> Bool {
        for name in (try? directory.entryNames()) ?? [] where pathExtension(of: name) == "json" {
            guard let discovered = try? directory.entry(named: name),
                isPlausiblyFresh(discovered.modificationDate, maxAge: maxAge, now: now)
            else { continue }
            if let file = try? directory.readFile(
                named: name, maximumByteCount: maximumPayloadBytes),
                isPlausiblyFresh(file.modificationDate, maxAge: maxAge, now: now)
            {
                return true
            }
        }
        return false
    }

    /// Fresh payloads (`*.json` within `maxAge`) directly inside `dir`, parsed.
    private static func freshPayloads(
        in directory: BoundedRegularFileReader.AnchoredDirectory,
        maxAge: TimeInterval,
        now: Date = Date()
    ) -> [StatuslinePayload] {
        var out: [StatuslinePayload] = []
        for name in (try? directory.entryNames()) ?? [] where pathExtension(of: name) == "json" {
            guard let discovered = try? directory.entry(named: name),
                isPlausiblyFresh(discovered.modificationDate, maxAge: maxAge, now: now),
                let file = try? directory.readFile(
                    named: name, maximumByteCount: maximumPayloadBytes),
                isPlausiblyFresh(file.modificationDate, maxAge: maxAge, now: now)
            else { continue }
            if let payload = try? parsePayload(file.data, capturedAt: file.modificationDate) {
                out.append(payload)
            }
        }
        return out
    }

    private static func isPlausiblyFresh(
        _ modificationDate: Date,
        maxAge: TimeInterval,
        now: Date
    ) -> Bool {
        let age = now.timeIntervalSince(modificationDate)
        return age >= -maximumFutureClockSkew && age < maxAge
    }

    private static func pathExtension(of name: String) -> String {
        (name as NSString).pathExtension
    }

    // MARK: - Data model

    public struct RateLimitWindow: Sendable {
        public let usedPercentage: Double
        public let resetsAt: Date?
    }

    public struct StatuslinePayload: Sendable {
        public struct Windows: Sendable {
            public let fiveHour: RateLimitWindow?
            public let sevenDay: RateLimitWindow?
            public let sevenDayOpus: RateLimitWindow?
        }

        public struct SessionMetadata: Sendable {
            public let id: String?
            public let name: String?
            public let cwd: String?
            public let modelId: String?
            public let modelDisplayName: String?
        }

        public struct ActivityCounters: Sendable {
            public let totalCostUsd: Double?
            public let totalApiDurationMs: Double?
            public let codeLinesAdded: Int?
            public let codeLinesRemoved: Int?
        }

        public let windows: Windows
        public let session: SessionMetadata
        public let counters: ActivityCounters
        public let cliVersion: String?
        public let capturedAt: Date

        public var fiveHour: RateLimitWindow? { windows.fiveHour }
        public var sevenDay: RateLimitWindow? { windows.sevenDay }
        public var sevenDayOpus: RateLimitWindow? { windows.sevenDayOpus }
        public var sessionId: String? { session.id }
        public var sessionName: String? { session.name }
        public var cwd: String? { session.cwd }
        public var modelId: String? { session.modelId }
        public var modelDisplayName: String? { session.modelDisplayName }
        public var totalCostUsd: Double? { counters.totalCostUsd }
        public var totalApiDurationMs: Double? { counters.totalApiDurationMs }
        public var codeLinesAdded: Int? { counters.codeLinesAdded }
        public var codeLinesRemoved: Int? { counters.codeLinesRemoved }
        /// Order-independent fingerprint of *every* session file in this account:
        /// each session's cost / API-duration / line counters, keyed by session id
        /// and sorted. Drives active-account detection.
        ///
        /// The display fields above (`totalCostUsd`, `codeLines…`) come from
        /// whichever file `mergePayloads` saw last, and the bridge rewrites every
        /// open session's file once a second — so with two concurrent windows on one
        /// account those values flip between polls with no real API activity. Using
        /// them as the activity signal made such an account look perpetually active
        /// and permanently win active-account selection over the one being typed in.
        public let activityFingerprint: String

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
            capturedAt: Date,
            activityFingerprint: String? = nil
        ) {
            self.windows = Windows(
                fiveHour: fiveHour, sevenDay: sevenDay, sevenDayOpus: sevenDayOpus)
            self.session = SessionMetadata(
                id: sessionId, name: sessionName, cwd: cwd, modelId: modelId,
                modelDisplayName: modelDisplayName)
            self.counters = ActivityCounters(
                totalCostUsd: totalCostUsd, totalApiDurationMs: totalApiDurationMs,
                codeLinesAdded: codeLinesAdded, codeLinesRemoved: codeLinesRemoved)
            self.cliVersion = cliVersion
            self.capturedAt = capturedAt
            self.activityFingerprint =
                activityFingerprint
                ?? Self.sessionFingerprint(
                    sessionId: sessionId, totalCostUsd: totalCostUsd,
                    totalApiDurationMs: totalApiDurationMs, codeLinesAdded: codeLinesAdded,
                    codeLinesRemoved: codeLinesRemoved)
        }

        /// One session's contribution to the account fingerprint. Fields that only
        /// move on a real API call; stable while a session sits idle even as its
        /// file is rewritten every second.
        static func sessionFingerprint(
            sessionId: String?,
            totalCostUsd: Double?,
            totalApiDurationMs: Double?,
            codeLinesAdded: Int?,
            codeLinesRemoved: Int?
        ) -> String {
            [
                sessionId ?? "-",
                totalCostUsd.map { "\($0)" } ?? "-",
                totalApiDurationMs.map { "\($0)" } ?? "-",
                codeLinesAdded.map { "\($0)" } ?? "-",
                codeLinesRemoved.map { "\($0)" } ?? "-",
            ].joined(separator: ",")
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
        readDataGrouped(dataRoot: dataDir, maxAge: maxAge)
    }

    /// Production-path core with an injectable app-data root. All children are
    /// resolved through the stable root descriptor.
    static func readDataGrouped(
        dataRoot dataRootURL: URL, maxAge: TimeInterval
    ) -> [String: StatuslinePayload] {
        guard
            let dataRoot = try? BoundedRegularFileReader.AnchoredDirectory(
                opening: dataRootURL)
        else { return [:] }
        let now = Date()
        var groups: [String: [StatuslinePayload]] = [:]
        if let sessions = try? dataRoot.directory(named: "sessions") {
            appendSessionPayloads(
                in: sessions, maxAge: maxAge, now: now, to: &groups)
        }
        if let legacy = freshPayload(
            named: "statusline.json", in: dataRoot, maxAge: maxAge, now: now)
        {
            groups[defaultAccountKey, default: []].append(legacy)
        }
        return mergePayloadGroups(groups)
    }

    /// Testable core of `readDataGrouped` with injectable paths.
    static func readDataGrouped(
        sessionsRoot: URL, legacyFile: URL?, maxAge: TimeInterval
    ) -> [String: StatuslinePayload] {
        let now = Date()
        var groups: [String: [StatuslinePayload]] = [:]

        if let root = try? BoundedRegularFileReader.AnchoredDirectory(opening: sessionsRoot) {
            appendSessionPayloads(in: root, maxAge: maxAge, now: now, to: &groups)
        }

        // Legacy single statusline.json → default account.
        if let legacyFile, let legacy = freshPayloadFile(legacyFile, maxAge: maxAge, now: now) {
            groups[defaultAccountKey, default: []].append(legacy)
        }

        return mergePayloadGroups(groups)
    }

    private static func appendSessionPayloads(
        in root: BoundedRegularFileReader.AnchoredDirectory,
        maxAge: TimeInterval,
        now: Date,
        to groups: inout [String: [StatuslinePayload]]
    ) {
        // Per-account subdirs (subdir name == account key).
        for name in (try? root.entryNames()) ?? [] {
            guard let account = try? root.directory(named: name) else { continue }
            let payloads = freshPayloads(in: account, maxAge: maxAge, now: now)
            if !payloads.isEmpty { groups[name, default: []] += payloads }
        }

        // Legacy flat files written by the pre-account snippet → default account.
        // (`freshPayloads(in:)` only accepts regular `*.json` files, so
        // subdirectories are skipped.)
        let legacyFlat = freshPayloads(in: root, maxAge: maxAge, now: now)
        if !legacyFlat.isEmpty { groups[defaultAccountKey, default: []] += legacyFlat }
    }

    private static func mergePayloadGroups(
        _ groups: [String: [StatuslinePayload]]
    ) -> [String: StatuslinePayload] {
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
        guard let contents = readRegularPayloadFile(url, maxAge: maxAge, now: now) else {
            return nil
        }
        return try? parsePayload(contents.data, capturedAt: contents.modificationDate)
    }

    private static func freshPayload(
        named name: String,
        in directory: BoundedRegularFileReader.AnchoredDirectory,
        maxAge: TimeInterval,
        now: Date
    ) -> StatuslinePayload? {
        guard let discovered = try? directory.entry(named: name),
            isPlausiblyFresh(discovered.modificationDate, maxAge: maxAge, now: now),
            let file = try? directory.readFile(
                named: name, maximumByteCount: maximumPayloadBytes),
            isPlausiblyFresh(file.modificationDate, maxAge: maxAge, now: now)
        else { return nil }
        return try? parsePayload(file.data, capturedAt: file.modificationDate)
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
        guard
            let base = payloads.max(by: {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
                return ($0.sessionId ?? $0.activityFingerprint)
                    < ($1.sessionId ?? $1.activityFingerprint)
            })
        else { return nil }

        let fiveHour = mostRecentWindow(payloads.compactMap(\.fiveHour))
        let sevenDay = mostRecentWindow(payloads.compactMap(\.sevenDay))
        let sevenDayOpus = mostRecentWindow(payloads.compactMap(\.sevenDayOpus))

        // Fingerprint every session, sorted, so the account's activity signal is
        // independent of which file happened to be written most recently.
        let fingerprint = payloads.map(\.activityFingerprint).sorted().joined(separator: ";")

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
            capturedAt: base.capturedAt,
            activityFingerprint: fingerprint
        )
    }

    internal static func readPayload(from statuslineFilePath: URL) throws -> StatuslinePayload? {
        guard let contents = readRegularPayloadFile(statuslineFilePath) else { return nil }
        return try parsePayload(contents.data, capturedAt: contents.modificationDate)
    }

    private struct RegularPayloadFile {
        let data: Data
        let modificationDate: Date
    }

    /// Reads one bounded regular file. The first `lstat` rejects links and special
    /// files without opening them. The open flags and `fstat` close the race between
    /// discovery and open, and keep a raced FIFO from blocking the poll.
    private static func readRegularPayloadFile(
        _ url: URL,
        maxAge: TimeInterval? = nil,
        now: Date = Date()
    ) -> RegularPayloadFile? {
        withRegularPayloadDescriptor(at: url) { descriptor, status in
            let modificationDate = modificationDate(from: status)
            if let maxAge,
                !isPlausiblyFresh(modificationDate, maxAge: maxAge, now: now)
            {
                return nil
            }

            let byteCount = Int(status.st_size)
            var data = Data(count: byteCount)
            var bytesRead = 0
            let readSucceeded = data.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return byteCount == 0 }
                while bytesRead < byteCount {
                    let count = pread(
                        descriptor,
                        baseAddress.advanced(by: bytesRead),
                        byteCount - bytesRead,
                        off_t(bytesRead))
                    if count > 0 {
                        bytesRead += count
                    } else if count == 0 {
                        return false
                    } else if errno != EINTR {
                        return false
                    }
                }
                return true
            }
            guard readSucceeded, bytesRead == byteCount else { return nil }
            return RegularPayloadFile(data: data, modificationDate: modificationDate)
        }
    }

    /// Checks freshness through the same no-follow regular-file boundary as reads.
    private static func isFreshRegularPayloadFile(
        named name: String,
        in directory: BoundedRegularFileReader.AnchoredDirectory,
        maxAge: TimeInterval,
        now: Date
    ) -> Bool {
        guard let discovered = try? directory.entry(named: name),
            isPlausiblyFresh(discovered.modificationDate, maxAge: maxAge, now: now),
            let file = try? directory.readFile(
                named: name, maximumByteCount: maximumPayloadBytes)
        else { return false }
        return isPlausiblyFresh(file.modificationDate, maxAge: maxAge, now: now)
    }

    private static func isFreshRegularPayloadFile(
        _ url: URL,
        maxAge: TimeInterval,
        now: Date
    ) -> Bool {
        withRegularPayloadDescriptor(at: url) { _, status in
            isPlausiblyFresh(modificationDate(from: status), maxAge: maxAge, now: now)
        } ?? false
    }

    private static func withRegularPayloadDescriptor<T>(
        at url: URL,
        body: (Int32, stat) -> T?
    ) -> T? {
        var discoveredStatus = stat()
        let lstatResult = url.path.withCString { Darwin.lstat($0, &discoveredStatus) }
        guard lstatResult == 0, (discoveredStatus.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            (openedStatus.st_mode & S_IFMT) == S_IFREG,
            openedStatus.st_size >= 0,
            openedStatus.st_size <= off_t(maximumPayloadBytes)
        else { return nil }
        return body(descriptor, openedStatus)
    }

    private static func modificationDate(from status: stat) -> Date {
        let seconds = TimeInterval(status.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds + nanoseconds)
    }

    private static func parsePayload(_ raw: Data, capturedAt: Date) throws -> StatuslinePayload? {
        guard !raw.isEmpty,
            let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }

        let rateLimits = json["rate_limits"] as? [String: Any]

        func window(_ key: String) -> RateLimitWindow? {
            guard let obj = rateLimits?[key] as? [String: Any],
                let pct = numericValue(obj["used_percentage"])
            else { return nil }
            let resetsAt = numericValue(obj["resets_at"]).flatMap {
                boundedProviderDate(timeIntervalSince1970: $0)
            }
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
            codeLinesAdded: boundedInt(numericValue(cost?["total_lines_added"])),
            codeLinesRemoved: boundedInt(numericValue(cost?["total_lines_removed"])),
            cliVersion: json["version"] as? String,
            capturedAt: capturedAt
        )
    }

    // MARK: - Settings helpers

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
            ?? boundedInt(statusLine["refreshInterval"] as? Double)
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

    private static func numericValue(_ value: Any?) -> Double? {
        let number: Double
        switch value {
        case let d as Double: number = d
        case let i as Int: number = Double(i)
        case let n as NSNumber: number = n.doubleValue
        default: return nil
        }
        return number.isFinite ? number : nil
    }

    /// Converts an external floating-point value without trapping. Truncation
    /// matches Swift's normal `Double`-to-`Int` conversion for valid values.
    static func boundedInt(_ value: Double?) -> Int? {
        guard let value else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }
}

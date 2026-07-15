import Foundation

/// Reads per-session JSONL files from ~/.claude/projects to get real-time message counts.
///
/// Supplements stats-cache.json which is only updated when Claude Code computes stats.
/// Counts "assistant" type entries (each = one API response) grouped by local calendar day.
public struct JournalReader: Sendable {

    public static var defaultProjectsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Maximum JSONL file size to scan in full; larger files are tail-read from the end.
    private static let maxFullReadBytes: UInt64 = 8 * 1024 * 1024
    private static let tailReadBytes: UInt64 = 512 * 1024

    /// One or more `projects/` roots (one per Claude config dir / account).
    /// Assistant-message counts are additive across accounts, so reads union them.
    public let projectsPaths: [URL]
    /// Back-compat: the first configured root.
    public var projectsPath: URL { projectsPaths.first ?? JournalReader.defaultProjectsPath }
    private let cache: JournalCache

    /// Multi-root: unions message counts across several config dirs' `projects/`.
    public init(projectsPaths: [URL], cache: JournalCache = .shared) {
        let roots = projectsPaths.isEmpty ? [JournalReader.defaultProjectsPath] : projectsPaths
        self.projectsPaths = roots.dedupedByResolvedPath()
        self.cache = cache
    }

    /// Single-root convenience (defaults to `~/.claude/projects`).
    public init(projectsPath: URL? = nil, cache: JournalCache = .shared) {
        self.init(
            projectsPaths: [projectsPath ?? JournalReader.defaultProjectsPath],
            cache: cache
        )
    }

    /// Returns a dict of local-date-string → assistant message count for the
    /// last `days` calendar days ending at `now` (inclusive).
    public func messageCounts(
        daysBack days: Int = 7,
        now: Date = Date()
    ) -> [String: Int] {
        let cal = Calendar.current
        let offset = -(max(days, 1) - 1)
        let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: now)!)
        let fm = FileManager.default

        var byDay: [String: Int] = [:]
        for projectsPath in projectsPaths {
            countRoot(projectsPath, cutoff: cutoff, fm: fm, into: &byDay)
        }
        return byDay
    }

    /// Accumulates one `projects/` root's assistant-message counts. An unreadable
    /// root returns without touching the accumulator.
    private func countRoot(
        _ projectsPath: URL,
        cutoff: Date,
        fm: FileManager,
        into byDay: inout [String: Int]
    ) {
        guard
            let projectDirs = try? fm.contentsOfDirectory(
                at: projectsPath,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return }

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir),
                isDir.boolValue
            else { continue }
            guard
                let jsonlFiles = try? fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for jsonlFile in jsonlFiles {
                guard jsonlFile.pathExtension == "jsonl" else { continue }
                guard let attrs = try? fm.attributesOfItem(atPath: jsonlFile.path),
                    let modDate = attrs[.modificationDate] as? Date,
                    modDate >= cutoff
                else { continue }
                let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                if let cached = cache.cachedCounts(
                    for: jsonlFile.path,
                    modDate: modDate,
                    fileSize: fileSize,
                    cutoff: cutoff
                ) {
                    merge(cached, into: &byDay)
                    continue
                }
                var fileCounts: [String: Int] = [:]
                countEntries(in: jsonlFile, fileSize: fileSize, since: cutoff, into: &fileCounts)
                cache.store(
                    path: jsonlFile.path,
                    modDate: modDate,
                    fileSize: fileSize,
                    counts: fileCounts
                )
                merge(fileCounts, into: &byDay)
            }
        }
    }

    // MARK: - Private helpers

    private func merge(_ source: [String: Int], into destination: inout [String: Int]) {
        for (day, count) in source {
            destination[day, default: 0] += count
        }
    }

    private func countEntries(
        in url: URL,
        fileSize: UInt64,
        since cutoff: Date,
        into counts: inout [String: Int]
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let readFrom: UInt64
        if fileSize > Self.maxFullReadBytes {
            readFrom = fileSize > Self.tailReadBytes ? fileSize - Self.tailReadBytes : 0
        } else {
            readFrom = 0
        }
        if readFrom > 0 {
            try? handle.seek(toOffset: readFrom)
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let startIndex = readFrom > 0 ? 1 : 0
        for line in lines.dropFirst(startIndex) {
            guard line.contains("\"assistant\""), line.contains("\"timestamp\"") else { continue }
            guard let entry = parseJournalLine(line) else { continue }
            guard entry.type == "assistant",
                let tsStr = entry.timestamp,
                let date = Self.parseTimestamp(tsStr),
                date >= cutoff
            else { continue }
            let dayStr = Self.dayString(from: date)
            counts[dayStr, default: 0] += 1
        }
    }

    private func parseJournalLine(_ line: Substring) -> JournalEntry? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JournalEntry.self, from: data)
    }

    /// Transcript files for one project dir: top-level session `*.jsonl` plus each
    /// session's `subagents/*.jsonl` — Claude Code writes subagent transcripts there
    /// and the parent transcript does **not** repeat their usage, so skipping them
    /// silently drops all delegated-agent activity. Context-fork transcripts
    /// (`agent-acompact-*`, `agent-aside_question-*`) replay the parent's history
    /// verbatim, usage blocks included, and are excluded to avoid double-counting.
    /// Non-recursive below `subagents/` (so `subagents/workflows/` journals, which
    /// carry no usage, are never walked).
    static func transcriptFiles(inProjectDir projectDir: URL, fm: FileManager) -> [URL] {
        guard
            let entries = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for entry in entries {
            if entry.pathExtension == "jsonl" {
                files.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let subagentsDir = entry.appendingPathComponent("subagents", isDirectory: true)
                guard
                    let subFiles = try? fm.contentsOfDirectory(
                        at: subagentsDir,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles])
                else { continue }
                for file in subFiles
                where file.pathExtension == "jsonl" && !isContextForkTranscript(file) {
                    files.append(file)
                }
            }
        }
        return files
    }

    static func isContextForkTranscript(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("agent-acompact-") || name.hasPrefix("agent-aside_question-")
    }

    // Cached formatters — `DateFormatter`/`ISO8601DateFormatter` are documented
    // thread-safe on macOS as long as they're never mutated after creation; these
    // are create-once, read-only. Allocating per call was the scanners' hottest
    // allocation (up to four `DateFormatter`s per transcript line).
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private nonisolated(unsafe) static let legacyTimestampFormatters: [DateFormatter] = {
        [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        ].map { format in
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            return f
        }
    }()
    private nonisolated(unsafe) static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseTimestamp(_ str: String) -> Date? {
        // Fast path: Claude Code emits ISO 8601 with exactly three fraction digits
        // and `Z` (what `.withFractionalSeconds` requires). The legacy chain stays
        // as the fallback for variants ISO8601DateFormatter rejects (e.g. `+0000`).
        if let date = isoFractional.date(from: str) { return date }
        if let date = isoPlain.date(from: str) { return date }
        for f in legacyTimestampFormatters {
            if let date = f.date(from: str) { return date }
        }
        return nil
    }

    public static func dayString(from date: Date) -> String {
        dayFormatter.string(from: date)
    }
}

// MARK: - Incremental cache

public final class JournalCache: @unchecked Sendable {
    public static let shared = JournalCache()

    private struct Entry {
        let modDate: Date
        let fileSize: UInt64
        let counts: [String: Int]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    func cachedCounts(
        for path: String,
        modDate: Date,
        fileSize: UInt64,
        cutoff: Date
    ) -> [String: Int]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path],
            entry.modDate == modDate,
            entry.fileSize == fileSize
        else { return nil }
        return entry.counts.filter { day, _ in
            guard let dayDate = JournalCache.parseDay(day) else { return false }
            return dayDate >= cutoff
        }
    }

    func store(path: String, modDate: Date, fileSize: UInt64, counts: [String: Int]) {
        lock.lock()
        entries[path] = Entry(modDate: modDate, fileSize: fileSize, counts: counts)
        lock.unlock()
    }

    // Read-only after creation; see the formatter-caching note in `JournalReader`.
    private nonisolated(unsafe) static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseDay(_ string: String) -> Date? {
        dayParser.date(from: string)
    }
}

/// Parses a timestamp that may be epoch seconds/milliseconds or ISO-8601
/// (with or without fractional seconds). Returns nil for empty/unparseable input.
func parseEpochOrISODate(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    if let number = Double(string) {
        // Heuristic: 13-digit values are milliseconds.
        let seconds = number > 1_000_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: string) { return date }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: string)
}

extension Array where Element == URL {
    /// Dedups roots by resolved path so overlapping discovery/custom entries
    /// (or symlinks) never double-count.
    func dedupedByResolvedPath() -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in self {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            if seen.insert(key).inserted { out.append(url) }
        }
        return out
    }
}

// MARK: - Private Codable

private struct JournalEntry: Codable {
    let type: String
    let timestamp: String?
}

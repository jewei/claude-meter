import ClaudeMeterCore
import Foundation

/// Shared transcript-walking and timestamp helpers for the `~/.claude/projects`
/// scanners (`CostUsageScanner`, `ActivityScanner`).
///
/// Statics only — the former instance side (per-day assistant-message counts plus
/// its own unbounded cache) had no callers in the app, the providers, or the
/// tests, so it was removed rather than left looking like live infrastructure.
public enum JournalReader {

    public static var defaultProjectsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
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
    private static let legacyTimestampFormatters: [DateFormatter] = {
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
    private static let dayFormatter: DateFormatter = {
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

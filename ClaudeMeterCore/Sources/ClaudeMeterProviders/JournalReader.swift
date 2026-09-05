import ClaudeMeterCore
import Darwin
import Foundation

/// Shared transcript-walking and timestamp helpers for the `~/.claude/projects`
/// scanners (`CostUsageScanner`, `ActivityScanner`).
///
/// Statics only — the former instance side (per-day assistant-message counts plus
/// its own unbounded cache) had no callers in the app, the providers, or the
/// tests, so it was removed rather than left looking like live infrastructure.
public enum JournalReader {

    struct TranscriptDiscovery {
        var files: [URL] = []
        var isPartial = false
    }

    struct TranscriptMetadata {
        let modificationDate: Date
        let fileSize: UInt64
    }

    struct TranscriptRead {
        let data: Data
        let baseOffset: UInt64
        let fileSize: UInt64
        let isPartial: Bool
    }

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
    static func transcriptFiles(
        inProjectDir projectDir: URL, fm: FileManager
    ) -> TranscriptDiscovery {
        var discovery = TranscriptDiscovery()
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        } catch {
            discovery.isPartial = true
            return discovery
        }

        for entry in entries {
            if entry.pathExtension == "jsonl" {
                do {
                    if try regularTranscriptMetadata(at: entry, fm: fm) != nil {
                        discovery.files.append(entry)
                    } else {
                        // A transcript-shaped directory, link, FIFO, or device is
                        // not safe input. Its omission makes the estimate partial.
                        discovery.isPartial = true
                    }
                } catch {
                    discovery.isPartial = true
                }
                continue
            }

            let entryType: FileAttributeType
            do {
                entryType = try fileType(at: entry, fm: fm)
            } catch {
                discovery.isPartial = true
                continue
            }
            guard entryType == .typeDirectory else { continue }

            let subagentsDir = entry.appendingPathComponent("subagents", isDirectory: true)
            let subagentsType: FileAttributeType
            do {
                subagentsType = try fileType(at: subagentsDir, fm: fm)
            } catch  where isMissingFileError(error) {
                continue
            } catch {
                discovery.isPartial = true
                continue
            }
            guard subagentsType == .typeDirectory else {
                discovery.isPartial = true
                continue
            }

            let subFiles: [URL]
            do {
                subFiles = try fm.contentsOfDirectory(
                    at: subagentsDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])
            } catch {
                discovery.isPartial = true
                continue
            }
            for file in subFiles
            where file.pathExtension == "jsonl" && !isContextForkTranscript(file) {
                do {
                    if try regularTranscriptMetadata(at: file, fm: fm) != nil {
                        discovery.files.append(file)
                    } else {
                        discovery.isPartial = true
                    }
                } catch {
                    discovery.isPartial = true
                }
            }
        }
        return discovery
    }

    /// Returns metadata only for a regular file. FileManager reports a symbolic
    /// link as `.typeSymbolicLink`, so links are never accepted as transcripts.
    static func regularTranscriptMetadata(
        at url: URL, fm: FileManager
    ) throws -> TranscriptMetadata? {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        guard let modificationDate = attributes[.modificationDate] as? Date,
            let size = attributes[.size] as? NSNumber
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return TranscriptMetadata(
            modificationDate: modificationDate,
            fileSize: size.uint64Value)
    }

    /// Opens one transcript without following links and reads at most the existing
    /// full-file or tail limit. `O_NONBLOCK` prevents a raced FIFO from blocking;
    /// `fstat` then rejects everything except a regular file.
    static func readRegularTranscript(
        at url: URL,
        maxFullReadBytes: UInt64,
        tailReadBytes: UInt64
    ) -> TranscriptRead? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_size >= 0
        else { return nil }

        let fileSize = UInt64(status.st_size)
        let tailRead = fileSize > maxFullReadBytes
        let requestedBytes = tailRead ? min(fileSize, tailReadBytes) : fileSize
        let baseOffset = tailRead ? fileSize - requestedBytes : 0
        guard requestedBytes <= UInt64(Int.max) else { return nil }

        var data = Data(count: Int(requestedBytes))
        var bytesRead = 0
        var readFailed = false
        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while bytesRead < rawBuffer.count {
                let count = pread(
                    descriptor,
                    baseAddress.advanced(by: bytesRead),
                    rawBuffer.count - bytesRead,
                    off_t(baseOffset) + off_t(bytesRead))
                if count > 0 {
                    bytesRead += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    readFailed = true
                    break
                }
            }
        }
        guard !readFailed else { return nil }
        if bytesRead < data.count {
            data.removeSubrange(bytesRead..<data.count)
        }
        return TranscriptRead(
            data: data,
            baseOffset: baseOffset,
            fileSize: fileSize,
            isPartial: tailRead || UInt64(bytesRead) != requestedBytes)
    }

    static func isMissingPath(_ url: URL, fm: FileManager) -> Bool {
        do {
            _ = try fileType(at: url, fm: fm)
            return false
        } catch {
            return isMissingFileError(error)
        }
    }

    static func isDirectory(_ url: URL, fm: FileManager) throws -> Bool {
        try fileType(at: url, fm: fm) == .typeDirectory
    }

    private static func fileType(at url: URL, fm: FileManager) throws -> FileAttributeType {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType else {
            throw CocoaError(.fileReadUnknown)
        }
        return type
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.fileNoSuchFile.rawValue
                || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
        }
        return nsError.domain == NSPOSIXErrorDomain
            && (nsError.code == Int(ENOENT) || nsError.code == Int(ENOTDIR))
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
    private final class ReadOnlyDateFormatters {
        let values: [DateFormatter]

        init(_ formats: [String]) {
            values = formats.map { format in
                let formatter = DateFormatter()
                formatter.dateFormat = format
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                return formatter
            }
        }
    }

    private nonisolated(unsafe) static let legacyTimestampFormatters = ReadOnlyDateFormatters([
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
    ])
    static func parseTimestamp(_ str: String) -> Date? {
        // Fast path: Claude Code emits ISO 8601 with exactly three fraction digits
        // and `Z` (what `.withFractionalSeconds` requires). The legacy chain stays
        // as the fallback for variants ISO8601DateFormatter rejects (e.g. `+0000`).
        if let date = isoFractional.date(from: str) { return date }
        if let date = isoPlain.date(from: str) { return date }
        for f in legacyTimestampFormatters.values {
            if let date = f.date(from: str) { return date }
        }
        return nil
    }

    public static func dayString(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day
        else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// Parses a timestamp that may be epoch seconds/milliseconds or ISO-8601
/// (with or without fractional seconds). Returns nil for empty/unparseable input.
func parseEpochOrISODate(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    if let number = Double(string), number.isFinite {
        // Heuristic: 13-digit values are milliseconds.
        let seconds = abs(number) > 1_000_000_000_000 ? number / 1000 : number
        return boundedProviderDate(timeIntervalSince1970: seconds)
    }
    guard let date = JournalReader.parseTimestamp(string) else { return nil }
    return boundedProviderDate(timeIntervalSince1970: date.timeIntervalSince1970)
}

/// Converts an external provider epoch without creating dates that Foundation's
/// ISO-8601 encoder cannot safely represent. These services did not exist before
/// 1970, and no usage or credential timestamp near year 3000 is plausible.
func boundedProviderDate(timeIntervalSince1970 seconds: TimeInterval) -> Date? {
    PersistedDateBounds.date(timeIntervalSince1970: seconds)
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

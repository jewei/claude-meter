import ClaudeMeterCore
import CryptoKit
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

    struct TranscriptIdentity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    struct TranscriptMetadata: Equatable, Sendable {
        let identity: TranscriptIdentity
        let modificationDate: Date
        let fileSize: UInt64
    }

    struct TranscriptRead {
        let metadata: TranscriptMetadata
        let isCacheable: Bool
        let data: Data
        let baseOffset: UInt64
        let fileSize: UInt64
        let isPartial: Bool
        var isAppend = false
        var appendCursor: AppendCursor? = nil
        var prefixBytesRead: UInt64 = 0
    }

    /// A checkpoint covers complete lines only. The digest covers every byte
    /// before offset, including transcript content that carries no usage.
    struct AppendCursor: Codable, Sendable {
        let offset: UInt64
        let digest: Data
        let identity: TranscriptIdentity
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

    /// Uses lstat so transcript symlinks remain excluded. Discovery and descriptor
    /// reads use the same conversion, including the modification-time precision.
    static func regularTranscriptMetadata(
        at url: URL, fm: FileManager
    ) throws -> TranscriptMetadata? {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return transcriptMetadata(status)
    }

    private static func transcriptMetadata(_ status: stat) -> TranscriptMetadata? {
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else { return nil }
        return TranscriptMetadata(
            identity: TranscriptIdentity(
                device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino)),
            modificationDate: Date(
                timeIntervalSince1970:
                    Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec)
                    / 1_000_000_000),
            fileSize: UInt64(status.st_size))
    }

    /// Opens one transcript without following links and reads at most the existing
    /// full-file or tail limit. `O_NONBLOCK` prevents a raced FIFO from blocking;
    /// `fstat` then rejects everything except a regular file.
    static func readRegularTranscript(
        at url: URL,
        maxFullReadBytes: UInt64,
        tailReadBytes: UInt64,
        maximumReadBytes: UInt64? = nil,
        trackAppend: Bool = false,
        appendCursor: AppendCursor? = nil,
        afterRead: (() -> Void)? = nil
    ) -> TranscriptRead? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
            let metadata = transcriptMetadata(status)
        else { return nil }

        let fileSize = UInt64(status.st_size)
        let tailRead = fileSize > maxFullReadBytes
        var hasher = SHA256()
        var isAppend = false
        var prefixBytesRead: UInt64 = 0
        if trackAppend, !tailRead, let cursor = appendCursor,
            cursor.identity == metadata.identity, cursor.offset <= fileSize,
            cursor.digest.count == SHA256.Digest.byteCount
        {
            // Hash in chunks rather than allocating the complete prefix. The
            // suffix read and the final metadata check use this same descriptor.
            var offset: UInt64 = 0
            var lastByte: UInt8?
            while offset < cursor.offset {
                guard !Task.isCancelled else { return nil }
                let count = min(UInt64(64 * 1024), cursor.offset - offset)
                guard let chunk = readBytes(descriptor, offset: offset, count: count),
                    chunk.count == Int(count)
                else { return nil }
                hasher.update(data: chunk)
                lastByte = chunk.last
                offset += count
            }
            prefixBytesRead = offset
            isAppend =
                (offset == 0 || lastByte == 0x0A)
                && Data(hasher.finalize()) == cursor.digest
            if !isAppend { hasher = SHA256() }
        }
        let baseOffset =
            isAppend
            ? appendCursor!.offset
            : tailRead ? fileSize - min(fileSize, tailReadBytes) : 0
        let requestedBytes = fileSize - baseOffset
        guard requestedBytes <= UInt64(Int.max) else { return nil }
        // Bound the descriptor's current size, not discovery metadata that can
        // change before open. Advisory scanners share a whole-scan byte budget.
        if let maximumReadBytes, requestedBytes > maximumReadBytes { return nil }
        guard let data = readBytes(descriptor, offset: baseOffset, count: requestedBytes) else {
            return nil
        }
        let committedCount =
            trackAppend && !tailRead ? data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0 : 0
        if trackAppend, !tailRead {
            hasher.update(data: data.prefix(committedCount))
        }
        afterRead?()
        var finalStatus = stat()
        let isCacheable =
            fstat(descriptor, &finalStatus) == 0
            && transcriptMetadata(finalStatus) == metadata && UInt64(data.count) == requestedBytes
        let nextCursor: AppendCursor? =
            trackAppend && !tailRead && isCacheable
            ? AppendCursor(
                offset: baseOffset + UInt64(committedCount), digest: Data(hasher.finalize()),
                identity: metadata.identity) : nil
        return TranscriptRead(
            metadata: metadata,
            isCacheable: isCacheable,
            data: data,
            baseOffset: baseOffset,
            fileSize: fileSize,
            isPartial: tailRead || !isCacheable,
            isAppend: isAppend, appendCursor: nextCursor, prefixBytesRead: prefixBytesRead)
    }

    private static func readBytes(_ descriptor: Int32, offset: UInt64, count: UInt64) -> Data? {
        guard count <= UInt64(Int.max), offset <= UInt64(Int64.max) - count else { return nil }
        var data = Data(count: Int(count))
        var bytesRead = 0
        var failed = false
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while bytesRead < buffer.count {
                if Task.isCancelled {
                    failed = true
                    break
                }
                let received = pread(
                    descriptor, base.advanced(by: bytesRead),
                    min(buffer.count - bytesRead, 256 * 1024),
                    off_t(offset) + off_t(bytesRead))
                if received > 0 {
                    bytesRead += received
                } else if received == 0 {
                    break
                } else if errno != EINTR {
                    failed = true
                    break
                }
            }
        }
        guard !failed else { return nil }
        data.removeSubrange(bytesRead..<data.count)
        return data
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

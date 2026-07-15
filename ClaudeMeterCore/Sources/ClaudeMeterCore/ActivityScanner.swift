import Foundation

/// A 7×24 grid of Claude Code activity (assistant-message counts) bucketed by
/// **local** weekday and hour, scanned from transcript `.jsonl` files. Powers the
/// popover's GitHub-style activity heatmap.
///
/// Counts are estimates: messages are deduped by `message.id` within a file so
/// streaming chunks don't inflate the tally, but very large files are tail-read
/// (last `tailReadBytes`) and may undercount — surfaced via `isPartial`.
public struct ActivityHeatmap: Sendable, Equatable {
    /// `counts[weekday][hour]` — weekday `0 = Monday … 6 = Sunday`, hour `0…23` local.
    public let counts: [[Int]]
    /// Total messages across the grid.
    public let total: Int
    /// `true` when one or more files were tail-read and totals may be incomplete.
    public let isPartial: Bool
    /// Distinct calendar days that had any activity (for a "data from Nd" label).
    public let daysCovered: Int

    public init(counts: [[Int]], total: Int, isPartial: Bool, daysCovered: Int) {
        self.counts = counts
        self.total = total
        self.isPartial = isPartial
        self.daysCovered = daysCovered
    }

    public static let empty = ActivityHeatmap(
        counts: Array(repeating: Array(repeating: 0, count: 24), count: 7),
        total: 0, isPartial: false, daysCovered: 0)

    public var isEmpty: Bool { total == 0 }

    /// Busiest single (weekday, hour) cell — the denominator for shading.
    public var peak: Int { counts.lazy.flatMap { $0 }.max() ?? 0 }
}

/// Scans transcript `.jsonl` files for assistant-message timestamps and buckets
/// them into a `7×24` local weekday/hour grid. Independent of `CostUsageScanner`
/// (no pricing, its own lightweight pass) so it can run on demand when the user
/// opens the heatmap rather than on every poll.
public struct ActivityScanner: Sendable {
    static let maxFullReadBytes: UInt64 = 8 * 1024 * 1024
    static let tailReadBytes: UInt64 = 4 * 1024 * 1024

    public let projectsPaths: [URL]
    private let cache: ActivityCache

    public init(projectsPaths: [URL], cache: ActivityCache = .shared) {
        self.projectsPaths = projectsPaths.dedupedByResolvedPath()
        self.cache = cache
    }

    public func scan(daysBack days: Int = 30, now: Date = Date()) -> ActivityHeatmap {
        let cal = Calendar.current
        let offset = -(max(days, 1) - 1)
        let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: now)!)
        // Local yyyy-MM-dd strings compare lexicographically, and `cutoff` is a local
        // start-of-day, so `bucket.day >= cutoffDay` ⟺ `timestamp >= cutoff`.
        let cutoffDay = JournalReader.dayString(from: cutoff)
        let fm = FileManager.default

        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var days = Set<String>()  // distinct local calendar days seen
        var total = 0
        var isPartial = false

        for projectsPath in projectsPaths {
            // Cooperative cancellation (per root and per file): the heatmap scan
            // keeps running after the popover closes without it. Cut-short grids
            // are marked partial.
            if Task.isCancelled {
                isPartial = true
                break
            }
            scanRoot(
                projectsPath, cutoff: cutoff, cutoffDay: cutoffDay, cal: cal, fm: fm,
                counts: &counts, days: &days, total: &total, isPartial: &isPartial)
        }

        return ActivityHeatmap(
            counts: counts, total: total, isPartial: isPartial, daysCovered: days.count)
    }

    private func scanRoot(
        _ projectsPath: URL,
        cutoff: Date,
        cutoffDay: String,
        cal: Calendar,
        fm: FileManager,
        counts: inout [[Int]],
        days: inout Set<String>,
        total: inout Int,
        isPartial: inout Bool
    ) {
        guard
            let projectDirs = try? fm.contentsOfDirectory(
                at: projectsPath, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return }

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }

            for file in JournalReader.transcriptFiles(inProjectDir: projectDir, fm: fm) {
                if Task.isCancelled {
                    isPartial = true
                    return
                }
                // Drain per-file transients (multi-MB Data/String reads) so peak
                // memory stays ~one file rather than scaling with the file count.
                autoreleasepool {
                    guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                        let modDate = attrs[.modificationDate] as? Date,
                        modDate >= cutoff
                    else { return }
                    let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

                    let scan: ActivityCache.FileScan
                    if let hit = cache.cached(
                        path: file.path, modDate: modDate, fileSize: fileSize)
                    {
                        scan = hit
                    } else {
                        scan = parseFile(file, fileSize: fileSize, cal: cal)
                        cache.store(
                            path: file.path, modDate: modDate, fileSize: fileSize, scan: scan)
                    }
                    if scan.isPartial { isPartial = true }
                    for (bucket, count) in scan.buckets where bucket.day >= cutoffDay {
                        counts[bucket.weekday][bucket.hour] += count
                        total += count
                        days.insert(bucket.day)
                    }
                }
            }
        }
    }

    /// Parses one transcript into per-(day, weekday, hour) message counts,
    /// **unfiltered** by window — filtering happens at read time so one cached
    /// entry serves any `daysBack`.
    private func parseFile(
        _ file: URL, fileSize: UInt64, cal: Calendar
    ) -> ActivityCache.FileScan {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return ActivityCache.FileScan(buckets: [:], isPartial: false)
        }
        defer { try? handle.close() }

        let tailRead = fileSize > Self.maxFullReadBytes
        let readFrom: UInt64 =
            tailRead ? (fileSize > Self.tailReadBytes ? fileSize - Self.tailReadBytes : 0) : 0
        if readFrom > 0 { try? handle.seek(toOffset: readFrom) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return ActivityCache.FileScan(buckets: [:], isPartial: tailRead)
        }

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // A tail read may start mid-line; drop the first partial line.
        let body = readFrom > 0 ? lines.dropFirst() : lines.dropFirst(0)

        // Dedup streaming chunks by message id within this file: each distinct
        // message counts once, at its timestamp's local weekday/hour.
        var seen = Set<String>()
        var buckets: [ActivityCache.Bucket: Int] = [:]
        let decoder = JSONDecoder()
        for (lineIndex, line) in body.enumerated() {
            guard line.contains("\"usage\""), line.contains("\"assistant\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                let entry = try? decoder.decode(ActivityLine.self, from: lineData),
                entry.type == "assistant",
                let tsStr = entry.timestamp,
                let date = JournalReader.parseTimestamp(tsStr)
            else { continue }

            let key = entry.message?.id ?? "line:\(file.lastPathComponent):\(lineIndex)"
            guard seen.insert(key).inserted else { continue }

            // Calendar weekday is 1=Sun…7=Sat; remap to 0=Mon…6=Sun.
            let bucket = ActivityCache.Bucket(
                day: JournalReader.dayString(from: date),
                weekday: (cal.component(.weekday, from: date) + 5) % 7,
                hour: cal.component(.hour, from: date))
            buckets[bucket, default: 0] += 1
        }
        return ActivityCache.FileScan(buckets: buckets, isPartial: tailRead)
    }
}

/// In-memory per-file cache for `ActivityScanner`, keyed by mtime + size — without
/// it every heatmap open re-reads and re-decodes hundreds of MB of transcripts.
/// Buckets are stored unfiltered (every day in the file) so one entry serves any
/// `daysBack`; only the active session's growing file misses. Deliberately not
/// persisted: the heatmap is on-demand, so the first open per app session pays the
/// parse and later opens are stat walks.
public final class ActivityCache: @unchecked Sendable {
    public static let shared = ActivityCache()

    struct Bucket: Hashable, Sendable {
        /// Local `yyyy-MM-dd` — enables read-time window filtering.
        let day: String
        /// `0 = Monday … 6 = Sunday`, matching `ActivityHeatmap.counts`.
        let weekday: Int
        let hour: Int
    }

    struct FileScan: Sendable {
        var buckets: [Bucket: Int]
        var isPartial: Bool
    }

    private struct Entry {
        let modDate: Date
        let fileSize: UInt64
        let scan: FileScan
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    func cached(path: String, modDate: Date, fileSize: UInt64) -> FileScan? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path],
            entry.modDate == modDate,
            entry.fileSize == fileSize
        else { return nil }
        return entry.scan
    }

    func store(path: String, modDate: Date, fileSize: UInt64, scan: FileScan) {
        lock.lock()
        entries[path] = Entry(modDate: modDate, fileSize: fileSize, scan: scan)
        lock.unlock()
    }
}

// MARK: - JSON shapes (minimal — only what activity bucketing needs)

private struct ActivityLine: Decodable {
    let type: String?
    let timestamp: String?
    let message: ActivityMessage?
}

private struct ActivityMessage: Decodable {
    let id: String?
}

import ClaudeMeterCore
import Foundation

/// Scans Claude Code's per-session JSONL transcripts under `~/.claude/projects`
/// to estimate token usage and dollar cost per model over a rolling window.
///
/// Each `assistant` line carries a `message.usage` block with cumulative token
/// counts for that response. Streaming emits multiple lines sharing the same
/// `message.id` + `requestId`; counts are cumulative, so we keep the **max** per
/// field per unique message rather than summing chunks (summing over-counts badly).
public struct CostUsageScanner: Sendable {

    /// One or more `projects/` roots (one per Claude config dir / account). Costs
    /// are additive across accounts, so the scan unions them.
    public let projectsPaths: [URL]
    /// Back-compat: the first configured root.
    public var projectsPath: URL { projectsPaths.first ?? JournalReader.defaultProjectsPath }
    private let pricing: ModelPricing
    private let cache: CostUsageCache
    private let calendar: Calendar

    /// Files larger than this are tail-read; transcripts are append-only so recent
    /// activity lives at the end.
    private static let maxFullReadBytes: UInt64 = 8 * 1024 * 1024
    private static let tailReadBytes: UInt64 = 4 * 1024 * 1024

    /// Multi-root: unions usage across several config dirs' `projects/` folders.
    public init(
        projectsPaths: [URL],
        pricing: ModelPricing = .current,
        cache: CostUsageCache = .shared,
        calendar: Calendar = .current
    ) {
        let roots = projectsPaths.isEmpty ? [JournalReader.defaultProjectsPath] : projectsPaths
        self.projectsPaths = roots.dedupedByResolvedPath()
        self.pricing = pricing
        self.cache = cache
        self.calendar = calendar
    }

    /// Single-root convenience (defaults to `~/.claude/projects`).
    public init(
        projectsPath: URL? = nil,
        pricing: ModelPricing = .current,
        cache: CostUsageCache = .shared,
        calendar: Calendar = .current
    ) {
        self.init(
            projectsPaths: [projectsPath ?? JournalReader.defaultProjectsPath],
            pricing: pricing,
            cache: cache,
            calendar: calendar
        )
    }

    /// Aggregated per-model usage/cost over the window.
    public func scan(daysBack days: Int = 7, now: Date = Date()) -> CostUsageResult {
        let cal = calendar
        let offset = -(max(days, 1) - 1)
        let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: now)!)
        let fm = FileManager.default

        // Sum tokens per (day, model) across every configured `projects/` root, then
        // collapse to per-model. Costs are additive across accounts; a single
        // unreadable root is skipped rather than zeroing the union.
        var byDayModel: [DayModelKey: TokenTotals] = [:]
        var isPartial = false
        for projectsPath in projectsPaths {
            // Cooperative cancellation (checked per root and per file): a caller
            // that no longer wants the answer shouldn't keep paying for disk I/O.
            // Cut-short totals are marked partial so they're never mistaken for
            // the full window.
            if Task.isCancelled {
                isPartial = true
                break
            }
            scanRoot(
                projectsPath,
                cutoff: cutoff,
                calendar: cal,
                fm: fm,
                into: &byDayModel,
                isPartial: &isPartial)
        }

        // Persist the (possibly updated) per-file cache so the next launch resumes
        // instead of re-parsing every transcript from scratch. Rate-limited: any
        // active session dirties the cache every poll, and a flush re-encodes every
        // resident entry — at the 2048-entry cap that was megabytes of atomic write
        // per minute for a cache whose only job is to avoid a cold-start re-parse.
        cache.flushIfDue(now: now)
        return aggregate(byDayModel, isPartial: isPartial)
    }

    /// Accumulates one `projects/` root into the running totals. A missing root is
    /// normal. Any existing root that cannot be read makes the result partial.
    private func scanRoot(
        _ projectsPath: URL,
        cutoff: Date,
        calendar: Calendar,
        fm: FileManager,
        into byDayModel: inout [DayModelKey: TokenTotals],
        isPartial: inout Bool
    ) {
        let projectDirs: [URL]
        do {
            projectDirs = try fm.contentsOfDirectory(
                at: projectsPath,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            if !JournalReader.isMissingPath(projectsPath, fm: fm) {
                isPartial = true
            }
            return
        }

        for projectDir in projectDirs {
            do {
                guard try JournalReader.isDirectory(projectDir, fm: fm) else { continue }
            } catch {
                isPartial = true
                continue
            }

            let discovery = JournalReader.transcriptFiles(inProjectDir: projectDir, fm: fm)
            if discovery.isPartial { isPartial = true }
            for file in discovery.files {
                if Task.isCancelled {
                    isPartial = true
                    return
                }
                // Bound peak memory to ~one file: each parse reads megabytes into
                // Data/String, so without draining per file the transients pile up
                // across every file in every account.
                autoreleasepool {
                    let metadata: JournalReader.TranscriptMetadata
                    do {
                        guard
                            let value = try JournalReader.regularTranscriptMetadata(
                                at: file, fm: fm)
                        else {
                            isPartial = true
                            return
                        }
                        metadata = value
                    } catch {
                        isPartial = true
                        return
                    }
                    guard metadata.modificationDate >= cutoff else { return }

                    let perFile: [DayModelKey: TokenTotals]
                    switch cache.lookup(
                        path: file.path,
                        modDate: metadata.modificationDate,
                        fileSize: metadata.fileSize,
                        timeZoneIdentifier: calendar.timeZone.identifier)
                    {
                    case .exact(let value, let wasPartial):
                        perFile = value
                        if wasPartial { isPartial = true }
                    case .miss:
                        let parse = parseFull(file: file, calendar: calendar)
                        perFile = parse.scan.value
                        if parse.scan.isPartial { isPartial = true }
                        // A transient open/read failure is not a statement that the
                        // unchanged transcript is empty. Do not turn that failure
                        // into an exact cache hit on the next scan. Successful tail
                        // reads stay cacheable even though their estimate is partial.
                        if parse.isCacheable {
                            cache.store(
                                file: file.path,
                                modDate: metadata.modificationDate,
                                fileSize: metadata.fileSize,
                                timeZoneIdentifier: calendar.timeZone.identifier,
                                scan: parse.scan)
                        }
                    }
                    for (key, totals) in perFile
                    where key.day >= cutoffDayString(cutoff, calendar: calendar) {
                        var combined = byDayModel[key, default: .zero]
                        if combined.add(totals) { isPartial = true }
                        byDayModel[key] = combined
                    }
                }
            }
        }
    }

    /// The result of scanning one transcript. Message chunks are deduplicated across
    /// the entire parsed range, not merely when adjacent.
    struct FileScan: Sendable {
        /// Retained in the disk format for compatibility; equal to `value` now that
        /// growth is conservatively re-parsed instead of assuming append identity.
        var committed: [DayModelKey: TokenTotals]
        /// End of the parsed range. Retained for the v2 disk representation.
        var pendingStart: UInt64
        var isPartial: Bool
        /// Complete deduplicated answer for this file.
        var value: [DayModelKey: TokenTotals]
    }

    /// Separates an incomplete but valid tail read from a transient I/O failure.
    /// Both scans are partial, but only the valid read can safely enter the cache.
    private struct FileParse: Sendable {
        let scan: FileScan
        let isCacheable: Bool
    }

    // MARK: - Parsing

    /// Full parse from scratch (cache miss). Large files are tail-read, so their
    /// result remains explicitly partial even after later growth.
    private func parseFull(file: URL, calendar: Calendar) -> FileParse {
        guard
            let read = JournalReader.readRegularTranscript(
                at: file,
                maxFullReadBytes: Self.maxFullReadBytes,
                tailReadBytes: Self.tailReadBytes)
        else {
            return FileParse(
                scan: FileScan(
                    committed: [:], pendingStart: 0, isPartial: true, value: [:]),
                isCacheable: false)
        }
        guard !read.data.isEmpty else {
            return FileParse(
                scan: FileScan(
                    committed: [:], pendingStart: read.fileSize,
                    isPartial: read.isPartial, value: [:]),
                isCacheable: true)
        }
        // A tail read may start mid-line; drop the first partial line.
        return FileParse(
            scan: scanBytes(
                read.data,
                baseOffset: read.baseOffset,
                dropFirstLine: read.baseOffset > 0,
                wasPartial: read.isPartial,
                calendar: calendar),
            isCacheable: true)
    }

    /// Core line scanner over a byte buffer. Streaming chunks are keyed across the
    /// entire range so interleaved messages still contribute one per-field maximum.
    private func scanBytes(
        _ data: Data,
        baseOffset: UInt64,
        dropFirstLine: Bool,
        wasPartial: Bool,
        calendar: Calendar
    ) -> FileScan {
        var isPartial = wasPartial
        // Collect newline-delimited line ranges, plus any trailing line with no final
        // newline. A genuinely in-progress trailing line fails to decode; any file
        // growth invalidates the cache and re-reads the complete range next time.
        var lineRanges: [Range<Int>] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var start = 0
            for i in 0..<raw.count where bytes[i] == 0x0A {
                lineRanges.append(start..<i)
                start = i + 1
            }
            if start < raw.count { lineRanges.append(start..<raw.count) }
        }

        let decoder = JSONDecoder()
        struct MessageAggregate {
            var day: String
            var model: String
            var totals: TokenTotals
        }
        var messages: [String: MessageAggregate] = [:]

        for (lineIndex, range) in lineRanges.enumerated() {
            if dropFirstLine && lineIndex == 0 { continue }
            let lineData = data.subdata(in: range)
            guard let line = String(data: lineData, encoding: .utf8),
                line.contains("\"usage\""), line.contains("\"assistant\""),
                let entry = try? decoder.decode(TranscriptLine.self, from: lineData),
                entry.type == "assistant",
                let message = entry.message,
                let usage = message.usage,
                let tsStr = entry.timestamp,
                let date = JournalReader.parseTimestamp(tsStr)
            else { continue }

            let model = message.model ?? "unknown"
            let key = dedupeKey(
                messageId: message.id, requestId: entry.requestId, lineIndex: lineIndex)
            if usage.hasInvalidCounter { isPartial = true }
            let cacheWrite = usage.cacheWriteSplit
            let totals = TokenTotals(
                input: max(usage.inputTokens ?? 0, 0),
                output: max(usage.outputTokens ?? 0, 0),
                cacheRead: max(usage.cacheReadInputTokens ?? 0, 0),
                cacheWrite5m: cacheWrite.fiveMinute,
                cacheWrite1h: cacheWrite.oneHour
            )

            if var existing = messages[key] {
                if existing.totals.takeMax(totals) { isPartial = true }
                messages[key] = existing
            } else {
                messages[key] = MessageAggregate(
                    day: JournalReader.dayString(from: date, calendar: calendar),
                    model: model,
                    totals: totals)
            }
        }

        var value: [DayModelKey: TokenTotals] = [:]
        for message in messages.values {
            let key = DayModelKey(day: message.day, model: message.model)
            var combined = value[key, default: .zero]
            if combined.add(message.totals) { isPartial = true }
            value[key] = combined
        }
        return FileScan(
            committed: value, pendingStart: baseOffset + UInt64(data.count),
            isPartial: isPartial, value: value)
    }

    /// Stable dedupe key for streaming chunks. Lines without ids are keyed by
    /// line index so distinct messages aren't collapsed.
    private func dedupeKey(messageId: String?, requestId: String?, lineIndex: Int) -> String {
        if let id = messageId, !id.isEmpty { return "\(id)|\(requestId ?? "")" }
        if let rid = requestId, !rid.isEmpty { return "|\(rid)|\(lineIndex)" }
        return "line:\(lineIndex)"
    }

    // MARK: - Aggregation

    private func aggregate(
        _ byDayModel: [DayModelKey: TokenTotals],
        isPartial: Bool
    ) -> CostUsageResult {
        var perModel: [String: TokenTotals] = [:]
        var resultIsPartial = isPartial

        for (key, totals) in byDayModel {
            var combined = perModel[key.model, default: .zero]
            if combined.add(totals) { resultIsPartial = true }
            perModel[key.model] = combined
        }

        let models = perModel.map { model, totals in
            ModelUsage(
                name: model,
                inputTokens: totals.input,
                outputTokens: totals.output,
                cacheReadTokens: totals.cacheRead,
                cacheWriteTokens: totals.cacheWrite,
                costUsd: cost(forModel: model, totals: totals)
            )
        }.sorted {
            let lhsCost = $0.costUsd ?? 0
            let rhsCost = $1.costUsd ?? 0
            return lhsCost == rhsCost ? $0.name < $1.name : lhsCost > rhsCost
        }

        return CostUsageResult(
            models: models,
            isPartialEstimate: resultIsPartial
        )
    }

    private func cost(forModel model: String, totals: TokenTotals) -> Double {
        pricing.cost(
            forModel: model,
            usage: .init(
                input: totals.input, output: totals.output, cacheRead: totals.cacheRead,
                cacheWrite5m: totals.cacheWrite5m, cacheWrite1h: totals.cacheWrite1h)
        )
    }

    private func cutoffDayString(_ cutoff: Date, calendar: Calendar) -> String {
        JournalReader.dayString(from: cutoff, calendar: calendar)
    }
}

// MARK: - Result

public struct CostUsageResult: Sendable, Equatable {
    public let models: [ModelUsage]
    /// `true` when totals can be incomplete or an invalid counter was clamped.
    public let isPartialEstimate: Bool

    public init(
        models: [ModelUsage],
        isPartialEstimate: Bool = false
    ) {
        self.models = models
        self.isPartialEstimate = isPartialEstimate
    }

    public static let empty = CostUsageResult(models: [], isPartialEstimate: false)

    public var isEmpty: Bool { models.isEmpty }
}

// MARK: - Internal aggregation types

struct DayModelKey: Hashable, Sendable {
    let day: String
    let model: String
}

struct TokenTotals: Sendable, Equatable {
    var input: Int
    var output: Int
    var cacheRead: Int
    /// Cache writes split by TTL tier — they bill differently (5m = 1.25× input,
    /// 1h = 2× input), so the tiers stay separate through aggregation.
    var cacheWrite5m: Int
    var cacheWrite1h: Int

    /// Combined cache-write tokens, for display. The tier fields can each be valid
    /// while their combined value is too large for `Int`, so this sum saturates.
    var cacheWrite: Int {
        let lhs = max(cacheWrite5m, 0)
        let rhs = max(cacheWrite1h, 0)
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    static let zero = TokenTotals(
        input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)

    /// Adds counters without trapping. Negative values are clamped to zero and
    /// overflowing sums saturate at `Int.max`. Returns `true` when either occurred.
    @discardableResult
    mutating func add(_ other: TokenTotals) -> Bool {
        var hadInvalidOrOverflow = false
        input = Self.saturatingAdd(input, other.input, invalid: &hadInvalidOrOverflow)
        output = Self.saturatingAdd(output, other.output, invalid: &hadInvalidOrOverflow)
        cacheRead = Self.saturatingAdd(cacheRead, other.cacheRead, invalid: &hadInvalidOrOverflow)
        cacheWrite5m = Self.saturatingAdd(
            cacheWrite5m, other.cacheWrite5m, invalid: &hadInvalidOrOverflow)
        cacheWrite1h = Self.saturatingAdd(
            cacheWrite1h, other.cacheWrite1h, invalid: &hadInvalidOrOverflow)
        if Self.sumOverflows(cacheWrite5m, cacheWrite1h) { hadInvalidOrOverflow = true }
        return hadInvalidOrOverflow
    }

    /// Keeps the larger of each field — for cumulative streaming chunks.
    @discardableResult
    mutating func takeMax(_ other: TokenTotals) -> Bool {
        var hadInvalidOrOverflow = false
        input = max(
            Self.nonnegative(input, invalid: &hadInvalidOrOverflow),
            Self.nonnegative(other.input, invalid: &hadInvalidOrOverflow))
        output = max(
            Self.nonnegative(output, invalid: &hadInvalidOrOverflow),
            Self.nonnegative(other.output, invalid: &hadInvalidOrOverflow))
        cacheRead = max(
            Self.nonnegative(cacheRead, invalid: &hadInvalidOrOverflow),
            Self.nonnegative(other.cacheRead, invalid: &hadInvalidOrOverflow))
        cacheWrite5m = max(
            Self.nonnegative(cacheWrite5m, invalid: &hadInvalidOrOverflow),
            Self.nonnegative(other.cacheWrite5m, invalid: &hadInvalidOrOverflow))
        cacheWrite1h = max(
            Self.nonnegative(cacheWrite1h, invalid: &hadInvalidOrOverflow),
            Self.nonnegative(other.cacheWrite1h, invalid: &hadInvalidOrOverflow))
        if Self.sumOverflows(cacheWrite5m, cacheWrite1h) { hadInvalidOrOverflow = true }
        return hadInvalidOrOverflow
    }

    private static func saturatingAdd(
        _ lhs: Int, _ rhs: Int, invalid: inout Bool
    ) -> Int {
        let safeLHS = nonnegative(lhs, invalid: &invalid)
        let safeRHS = nonnegative(rhs, invalid: &invalid)
        let (sum, overflow) = safeLHS.addingReportingOverflow(safeRHS)
        if overflow {
            invalid = true
            return .max
        }
        return sum
    }

    private static func nonnegative(_ value: Int, invalid: inout Bool) -> Int {
        guard value >= 0 else {
            invalid = true
            return 0
        }
        return value
    }

    private static func sumOverflows(_ lhs: Int, _ rhs: Int) -> Bool {
        lhs.addingReportingOverflow(rhs).overflow
    }
}

// MARK: - JSON shapes

private struct TranscriptLine: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let message: TranscriptMessage?
}

private struct TranscriptMessage: Decodable {
    let id: String?
    let model: String?
    let usage: TranscriptUsage?
}

private struct TranscriptUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheCreation: CacheCreationBreakdown?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
    }

    /// Splits cache writes into (5m, 1h) tier tokens. The explicit breakdown wins
    /// when at least one sub-field is present (the legacy total duplicates its sum);
    /// older transcripts without one attribute the whole legacy total to the 5m
    /// tier. Never sum breakdown + legacy — that double-counts.
    var cacheWriteSplit: (fiveMinute: Int, oneHour: Int) {
        if let b = cacheCreation, b.ephemeral5m != nil || b.ephemeral1h != nil {
            return (max(b.ephemeral5m ?? 0, 0), max(b.ephemeral1h ?? 0, 0))
        }
        return (max(cacheCreationInputTokens ?? 0, 0), 0)
    }

    var hasInvalidCounter: Bool {
        [
            inputTokens,
            outputTokens,
            cacheReadInputTokens,
            cacheCreationInputTokens,
            cacheCreation?.ephemeral5m,
            cacheCreation?.ephemeral1h,
        ].compactMap { $0 }.contains { $0 < 0 }
    }
}

private struct CacheCreationBreakdown: Decodable {
    let ephemeral5m: Int?
    let ephemeral1h: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral5m = "ephemeral_5m_input_tokens"
        case ephemeral1h = "ephemeral_1h_input_tokens"
    }
}

// MARK: - Incremental cache

/// Caches per-file `(day, model) -> tokens` aggregations, invalidated by file
/// mtime + size. Window filtering happens at read time so the same cache serves
/// any `daysBack`. Persisted to disk (Application Support, `0o600`) so a relaunch
/// avoids re-parsing unchanged transcripts. Changed files are conservatively
/// re-parsed because mtime + size cannot prove that growth was append-only.
public final class CostUsageCache: @unchecked Sendable {
    public static let shared = CostUsageCache(persistenceURL: CostUsageCache.defaultPersistenceURL)

    /// Result of a per-file lookup.
    enum Lookup {
        /// File unchanged (mtime + size match) — totals served directly.
        case exact(value: [DayModelKey: TokenTotals], isPartial: Bool)
        /// No usable entry (absent, shrunk, or rewritten in place) — full parse needed.
        case miss
    }

    private struct Entry {
        var modDate: Date
        var fileSize: UInt64
        var timeZoneIdentifier: String
        var parsedBytes: UInt64
        var committed: [DayModelKey: TokenTotals]
        var value: [DayModelKey: TokenTotals]
        var isPartial: Bool
    }

    // Subagent transcripts roughly triple the file count vs top-level-only scans,
    // so the cap is sized to keep a heavy month fully resident.
    static let maxEntries = 2048
    private static let maximumPersistenceFileBytes = 64 * 1_024 * 1_024
    // v3: cache identity includes the time zone used for local-day buckets. Older
    // versions are discarded: v1 cannot split cache-write tiers, and v2 can serve
    // a wrong boundary day after travel.
    private static let diskVersion = 3

    private let persistenceURL: URL?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var recency = LRUKeyIndex<String>()
    private var didLoad: Bool
    private var dirty = false
    private var lastFlushAt: Date?

    /// In-memory only (used by tests); no disk I/O. Use `shared` for the persisted cache.
    public init() {
        self.persistenceURL = nil
        self.didLoad = true
    }

    init(persistenceURL: URL?) {
        self.persistenceURL = persistenceURL
        self.didLoad = false
    }

    var entryCount: Int {
        lock.withLock {
            loadIfNeededLocked()
            return entries.count
        }
    }

    func lookup(
        path: String,
        modDate: Date,
        fileSize: UInt64,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard let entry = entries[path] else { return .miss }
        if entry.modDate == modDate,
            entry.fileSize == fileSize,
            entry.timeZoneIdentifier == timeZoneIdentifier
        {
            recency.touch(path)
            return .exact(value: entry.value, isPartial: entry.isPartial)
        }
        // mtime+size cannot prove that growth was append-only: editors and sync tools
        // can replace a transcript with a larger file. Re-parse on every stamp change
        // so stale committed totals can never be merged into unrelated contents.
        return .miss
    }

    func store(
        file path: String,
        modDate: Date,
        fileSize: UInt64,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        scan: CostUsageScanner.FileScan
    ) {
        lock.lock()
        loadIfNeededLocked()
        entries[path] = Entry(
            modDate: modDate,
            fileSize: fileSize,
            timeZoneIdentifier: timeZoneIdentifier,
            parsedBytes: scan.pendingStart,
            committed: scan.committed, value: scan.value, isPartial: scan.isPartial)
        recency.touch(path)
        dirty = true
        while entries.count > Self.maxEntries, let oldest = recency.popLeastRecent() {
            entries.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    /// Minimum wall-clock gap between disk flushes. Losing up to this much cache
    /// progress to a crash costs one transcript re-parse; writing
    /// the whole cache every 60 s poll is not.
    static let minFlushInterval: TimeInterval = 10 * 60

    /// Writes the cache to disk if anything changed since the last flush.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let url = persistenceURL else { return }
        persistLocked(to: url)
        dirty = false
    }

    /// Flushes at most once per `minFlushInterval`. The first flush of a process
    /// always goes through, so a short-lived run still persists its work.
    func flushIfDue(now: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let url = persistenceURL else { return }
        if let last = lastFlushAt, now.timeIntervalSince(last) < Self.minFlushInterval { return }
        persistLocked(to: url)
        lastFlushAt = now
        dirty = false
    }

    /// Drops rebuildable in-memory entries under system memory pressure while
    /// leaving the last flushed disk cache intact for a future process. We do not
    /// immediately reload that file in this process: doing so on the next poll
    /// would undo the relief. Active-window files repopulate lazily as they are
    /// scanned; losing unflushed cache progress affects performance, never totals.
    @discardableResult
    public func trimMemory() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let removed = entries.count
        entries.removeAll(keepingCapacity: false)
        recency.removeAll()
        didLoad = true
        dirty = false
        return removed
    }

    // MARK: - Persistence

    static var defaultPersistenceURL: URL? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: false)
        else { return nil }
        return
            base
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent("cost-usage-cache.json")
    }

    private func loadIfNeededLocked() {
        guard !didLoad else { return }
        didLoad = true
        guard let url = persistenceURL,
            let data = try? BoundedRegularFileReader.read(
                at: url, maximumByteCount: Self.maximumPersistenceFileBytes),
            let disk = try? JSONDecoder().decode(DiskCache.self, from: data),
            disk.version == Self.diskVersion
        else { return }
        let fm = FileManager.default
        // The disk array is oldest-to-newest. Keep the newest valid entries, but
        // replay them in the original order so the in-memory LRU matches the file.
        var retained: [DiskEntry] = []
        retained.reserveCapacity(Self.maxEntries)
        for diskEntry in disk.entries.reversed()
        where fm.fileExists(atPath: diskEntry.path) {
            retained.append(diskEntry)
            if retained.count == Self.maxEntries { break }
        }
        for de in retained.reversed() {
            entries[de.path] = Entry(
                modDate: Date(timeIntervalSinceReferenceDate: de.modDate),
                fileSize: de.fileSize,
                timeZoneIdentifier: de.timeZoneIdentifier,
                parsedBytes: de.parsedBytes,
                committed: Self.dict(from: de.committed),
                value: Self.dict(from: de.value),
                isPartial: de.isPartial)
            recency.touch(de.path)
        }
    }

    private func persistLocked(to url: URL) {
        let disk = DiskCache(
            version: Self.diskVersion,
            entries: recency.keysFromLeastToMostRecent().compactMap { path in
                guard let e = entries[path] else { return nil }
                return DiskEntry(
                    path: path, modDate: e.modDate.timeIntervalSinceReferenceDate,
                    fileSize: e.fileSize,
                    timeZoneIdentifier: e.timeZoneIdentifier,
                    parsedBytes: e.parsedBytes, isPartial: e.isPartial,
                    committed: Self.rows(from: e.committed), value: Self.rows(from: e.value))
            })
        guard let data = try? JSONEncoder().encode(disk) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best-effort cache; a failed write just means we re-parse next launch.
        }
    }

    private static func rows(from dict: [DayModelKey: TokenTotals]) -> [DiskRow] {
        dict.map { key, t in
            DiskRow(
                d: key.day, m: key.model, i: t.input, o: t.output, cr: t.cacheRead,
                cw: t.cacheWrite5m, c1: t.cacheWrite1h)
        }
    }

    private static func dict(from rows: [DiskRow]) -> [DayModelKey: TokenTotals] {
        var out: [DayModelKey: TokenTotals] = [:]
        for r in rows {
            out[DayModelKey(day: r.d, model: r.m)] = TokenTotals(
                input: r.i, output: r.o, cacheRead: r.cr, cacheWrite5m: r.cw, cacheWrite1h: r.c1)
        }
        return out
    }

    private struct DiskCache: Codable {
        var version: Int
        var entries: [DiskEntry]
    }

    private struct DiskEntry: Codable {
        var path: String
        var modDate: Double
        var fileSize: UInt64
        var timeZoneIdentifier: String
        var parsedBytes: UInt64
        var isPartial: Bool
        var committed: [DiskRow]
        var value: [DiskRow]
    }

    private struct DiskRow: Codable {
        var d: String
        var m: String
        var i: Int
        var o: Int
        var cr: Int
        /// 5m-tier cache-write tokens.
        var cw: Int
        /// 1h-tier cache-write tokens.
        var c1: Int
    }
}

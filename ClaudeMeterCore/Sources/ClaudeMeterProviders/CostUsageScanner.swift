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

    /// Files larger than this are tail-read; transcripts are append-only so recent
    /// activity lives at the end.
    private static let maxFullReadBytes: UInt64 = 8 * 1024 * 1024
    private static let tailReadBytes: UInt64 = 4 * 1024 * 1024

    /// Multi-root: unions usage across several config dirs' `projects/` folders.
    public init(
        projectsPaths: [URL],
        pricing: ModelPricing = .current,
        cache: CostUsageCache = .shared
    ) {
        let roots = projectsPaths.isEmpty ? [JournalReader.defaultProjectsPath] : projectsPaths
        self.projectsPaths = roots.dedupedByResolvedPath()
        self.pricing = pricing
        self.cache = cache
    }

    /// Single-root convenience (defaults to `~/.claude/projects`).
    public init(
        projectsPath: URL? = nil,
        pricing: ModelPricing = .current,
        cache: CostUsageCache = .shared
    ) {
        self.init(
            projectsPaths: [projectsPath ?? JournalReader.defaultProjectsPath],
            pricing: pricing,
            cache: cache
        )
    }

    /// Aggregated per-model usage/cost over the window.
    public func scan(daysBack days: Int = 7, now: Date = Date()) -> CostUsageResult {
        let cal = Calendar.current
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
            scanRoot(projectsPath, cutoff: cutoff, fm: fm, into: &byDayModel, isPartial: &isPartial)
        }

        // Persist the (possibly updated) per-file cache so the next launch resumes
        // instead of re-parsing every transcript from scratch. Rate-limited: any
        // active session dirties the cache every poll, and a flush re-encodes every
        // resident entry — at the 2048-entry cap that was megabytes of atomic write
        // per minute for a cache whose only job is to avoid a cold-start re-parse.
        cache.flushIfDue(now: now)
        return aggregate(byDayModel, isPartial: isPartial)
    }

    /// Accumulates one `projects/` root into the running totals. An unreadable root
    /// returns without touching the accumulators.
    private func scanRoot(
        _ projectsPath: URL,
        cutoff: Date,
        fm: FileManager,
        into byDayModel: inout [DayModelKey: TokenTotals],
        isPartial: inout Bool
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
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }

            for file in JournalReader.transcriptFiles(inProjectDir: projectDir, fm: fm) {
                if Task.isCancelled {
                    isPartial = true
                    return
                }
                // Bound peak memory to ~one file: each parse reads megabytes into
                // Data/String, so without draining per file the transients pile up
                // across every file in every account.
                autoreleasepool {
                    guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                        let modDate = attrs[.modificationDate] as? Date,
                        modDate >= cutoff
                    else { return }
                    let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

                    let perFile: [DayModelKey: TokenTotals]
                    switch cache.lookup(path: file.path, modDate: modDate, fileSize: fileSize) {
                    case .exact(let value, let wasPartial):
                        perFile = value
                        if wasPartial { isPartial = true }
                    case .miss:
                        let scan = parseFull(file: file, fileSize: fileSize)
                        perFile = scan.value
                        if scan.isPartial { isPartial = true }
                        cache.store(
                            file: file.path, modDate: modDate, fileSize: fileSize, scan: scan)
                    }
                    for (key, totals) in perFile where key.day >= cutoffDayString(cutoff) {
                        byDayModel[key, default: .zero].add(totals)
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

    // MARK: - Parsing

    /// Full parse from scratch (cache miss). Large files are tail-read, so their
    /// result remains explicitly partial even after later growth.
    private func parseFull(file: URL, fileSize: UInt64) -> FileScan {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return FileScan(committed: [:], pendingStart: 0, isPartial: true, value: [:])
        }
        defer { try? handle.close() }

        let tailRead = fileSize > Self.maxFullReadBytes
        let readFrom: UInt64 =
            tailRead
            ? (fileSize > Self.tailReadBytes ? fileSize - Self.tailReadBytes : 0)
            : 0
        if readFrom > 0 { try? handle.seek(toOffset: readFrom) }
        guard let data = try? handle.readToEnd() else {
            return FileScan(committed: [:], pendingStart: fileSize, isPartial: true, value: [:])
        }
        guard !data.isEmpty else {
            return FileScan(committed: [:], pendingStart: fileSize, isPartial: tailRead, value: [:])
        }
        // A tail read may start mid-line; drop the first partial line.
        return scanBytes(
            data, baseOffset: readFrom, dropFirstLine: readFrom > 0, wasPartial: tailRead)
    }

    /// Core line scanner over a byte buffer. Streaming chunks are keyed across the
    /// entire range so interleaved messages still contribute one per-field maximum.
    private func scanBytes(
        _ data: Data, baseOffset: UInt64, dropFirstLine: Bool, wasPartial: Bool
    ) -> FileScan {
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
            let cacheWrite = usage.cacheWriteSplit
            let totals = TokenTotals(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheWrite5m: cacheWrite.fiveMinute,
                cacheWrite1h: cacheWrite.oneHour
            )

            if var existing = messages[key] {
                existing.totals.takeMax(totals)
                messages[key] = existing
            } else {
                messages[key] = MessageAggregate(
                    day: JournalReader.dayString(from: date), model: model, totals: totals)
            }
        }

        var value: [DayModelKey: TokenTotals] = [:]
        for message in messages.values {
            value[DayModelKey(day: message.day, model: message.model), default: .zero]
                .add(message.totals)
        }
        return FileScan(
            committed: value, pendingStart: baseOffset + UInt64(data.count),
            isPartial: wasPartial, value: value)
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

        for (key, totals) in byDayModel {
            perModel[key.model, default: .zero].add(totals)
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
            isPartialEstimate: isPartial
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

    private func cutoffDayString(_ cutoff: Date) -> String {
        JournalReader.dayString(from: cutoff)
    }
}

// MARK: - Result

public struct CostUsageResult: Sendable, Equatable {
    public let models: [ModelUsage]
    /// `true` when one or more transcript files were tail-read and totals may be incomplete.
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

    /// Combined cache-write tokens, for display.
    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    static let zero = TokenTotals(
        input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)

    mutating func add(_ other: TokenTotals) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
    }

    /// Keeps the larger of each field — for cumulative streaming chunks.
    mutating func takeMax(_ other: TokenTotals) {
        input = max(input, other.input)
        output = max(output, other.output)
        cacheRead = max(cacheRead, other.cacheRead)
        cacheWrite5m = max(cacheWrite5m, other.cacheWrite5m)
        cacheWrite1h = max(cacheWrite1h, other.cacheWrite1h)
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
            return (b.ephemeral5m ?? 0, b.ephemeral1h ?? 0)
        }
        return (cacheCreationInputTokens ?? 0, 0)
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
        var parsedBytes: UInt64
        var committed: [DayModelKey: TokenTotals]
        var value: [DayModelKey: TokenTotals]
        var isPartial: Bool
    }

    // Subagent transcripts roughly triple the file count vs top-level-only scans,
    // so the cap is sized to keep a heavy month fully resident.
    private static let maxEntries = 2048
    // v2: cache-write totals split into 5m/1h tiers. Old caches are discarded
    // (one-time full re-parse) rather than migrated — a v1 total can't be split.
    private static let diskVersion = 2

    private let persistenceURL: URL?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var accessRanks: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0
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

    func lookup(path: String, modDate: Date, fileSize: UInt64) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard let entry = entries[path] else { return .miss }
        if entry.modDate == modDate && entry.fileSize == fileSize {
            touchLocked(path)
            return .exact(value: entry.value, isPartial: entry.isPartial)
        }
        // mtime+size cannot prove that growth was append-only: editors and sync tools
        // can replace a transcript with a larger file. Re-parse on every stamp change
        // so stale committed totals can never be merged into unrelated contents.
        return .miss
    }

    func store(
        file path: String, modDate: Date, fileSize: UInt64, scan: CostUsageScanner.FileScan
    ) {
        lock.lock()
        loadIfNeededLocked()
        entries[path] = Entry(
            modDate: modDate, fileSize: fileSize, parsedBytes: scan.pendingStart,
            committed: scan.committed, value: scan.value, isPartial: scan.isPartial)
        touchLocked(path)
        dirty = true
        while entries.count > Self.maxEntries,
            let oldest = accessRanks.min(by: { $0.value < $1.value })?.key
        {
            entries.removeValue(forKey: oldest)
            accessRanks.removeValue(forKey: oldest)
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

    private func touchLocked(_ path: String) {
        accessCounter &+= 1
        accessRanks[path] = accessCounter
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
            let data = try? Data(contentsOf: url),
            let disk = try? JSONDecoder().decode(DiskCache.self, from: data),
            disk.version == Self.diskVersion
        else { return }
        let fm = FileManager.default
        for de in disk.entries where fm.fileExists(atPath: de.path) {
            entries[de.path] = Entry(
                modDate: Date(timeIntervalSinceReferenceDate: de.modDate),
                fileSize: de.fileSize,
                parsedBytes: de.parsedBytes,
                committed: Self.dict(from: de.committed),
                value: Self.dict(from: de.value),
                isPartial: de.isPartial)
            touchLocked(de.path)
        }
    }

    private func persistLocked(to url: URL) {
        let disk = DiskCache(
            version: Self.diskVersion,
            entries: accessRanks.sorted(by: { $0.value < $1.value }).compactMap { path, _ in
                guard let e = entries[path] else { return nil }
                return DiskEntry(
                    path: path, modDate: e.modDate.timeIntervalSinceReferenceDate,
                    fileSize: e.fileSize,
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

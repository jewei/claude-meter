import Foundation

/// Scans Claude Code's per-session JSONL transcripts under `~/.claude/projects`
/// to estimate token usage and dollar cost per model over a rolling window.
///
/// Each `assistant` line carries a `message.usage` block with cumulative token
/// counts for that response. Streaming emits multiple lines sharing the same
/// `message.id` + `requestId`; counts are cumulative, so we keep the **max** per
/// field per unique message rather than summing chunks (summing over-counts badly).
public struct CostUsageScanner: Sendable {

    public let projectsPath: URL
    private let pricing: ModelPricing
    private let cache: CostUsageCache

    /// Files larger than this are tail-read; transcripts are append-only so recent
    /// activity lives at the end.
    private static let maxFullReadBytes: UInt64 = 8 * 1024 * 1024
    private static let tailReadBytes: UInt64 = 4 * 1024 * 1024

    public init(
        projectsPath: URL? = nil,
        pricing: ModelPricing = .current,
        cache: CostUsageCache = .shared
    ) {
        self.projectsPath = projectsPath ?? JournalReader.defaultProjectsPath
        self.pricing = pricing
        self.cache = cache
    }

    /// Aggregated per-model usage/cost over the window.
    public func scan(daysBack days: Int = 7, now: Date = Date()) -> CostUsageResult {
        let cal = Calendar.current
        let offset = -(max(days, 1) - 1)
        let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: now)!)
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsPath,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return .empty }

        // Sum tokens per (day, model) across all files, then collapse to per-model.
        var byDayModel: [DayModelKey: TokenTotals] = [:]
        var isPartial = false

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue,
                  let jsonlFiles = try? fm.contentsOfDirectory(
                      at: projectDir,
                      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                      options: [.skipsHiddenFiles]
                  ) else { continue }

            for file in jsonlFiles where file.pathExtension == "jsonl" {
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate >= cutoff else { continue }
                let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

                let perFile: [DayModelKey: TokenTotals]
                if let cached = cache.cached(for: file.path, modDate: modDate, fileSize: fileSize) {
                    perFile = cached.totals
                    if cached.isPartial { isPartial = true }
                } else {
                    let parsed = parse(file: file, fileSize: fileSize)
                    perFile = parsed.totals
                    if parsed.isPartial { isPartial = true }
                    cache.store(
                        path: file.path,
                        modDate: modDate,
                        fileSize: fileSize,
                        value: parsed.totals,
                        isPartial: parsed.isPartial
                    )
                }
                for (key, totals) in perFile where key.day >= cutoffDayString(cutoff) {
                    byDayModel[key, default: .zero].add(totals)
                }
            }
        }

        return aggregate(byDayModel, isPartial: isPartial)
    }

    private struct ParseResult {
        let totals: [DayModelKey: TokenTotals]
        let isPartial: Bool
    }

    // MARK: - Parsing

    private func parse(file: URL, fileSize: UInt64) -> ParseResult {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return ParseResult(totals: [:], isPartial: false)
        }
        defer { try? handle.close() }

        let tailRead = fileSize > Self.maxFullReadBytes
        let readFrom: UInt64 = tailRead
            ? (fileSize > Self.tailReadBytes ? fileSize - Self.tailReadBytes : 0)
            : 0
        if readFrom > 0 { try? handle.seek(toOffset: readFrom) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return ParseResult(totals: [:], isPartial: tailRead)
        }

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // A tail read may start mid-line; drop the first partial line.
        let body = readFrom > 0 ? lines.dropFirst() : lines.dropFirst(0)

        // Dedup cumulative streaming chunks by message id + request id.
        var unique: [String: ParsedMessage] = [:]
        let decoder = JSONDecoder()
        for (lineIndex, line) in body.enumerated() {
            guard line.contains("\"usage\""), line.contains("\"assistant\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(TranscriptLine.self, from: lineData),
                  entry.type == "assistant",
                  let message = entry.message,
                  let usage = message.usage,
                  let tsStr = entry.timestamp,
                  let date = JournalReader.parseTimestamp(tsStr) else { continue }

            let model = message.model ?? "unknown"
            let key = dedupeKey(
                messageId: message.id,
                requestId: entry.requestId,
                lineIndex: lineIndex
            )
            let totals = TokenTotals(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheWrite: usage.cacheCreationInputTokens ?? 0
            )
            if var existing = unique[key] {
                existing.totals.takeMax(totals)
                unique[key] = existing
            } else {
                unique[key] = ParsedMessage(
                    day: JournalReader.dayString(from: date),
                    model: model,
                    totals: totals
                )
            }
        }

        var result: [DayModelKey: TokenTotals] = [:]
        for msg in unique.values {
            result[DayModelKey(day: msg.day, model: msg.model), default: .zero].add(msg.totals)
        }
        return ParseResult(totals: result, isPartial: tailRead)
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
        }.sorted { ($0.costUsd ?? 0) > ($1.costUsd ?? 0) }

        return CostUsageResult(
            models: models,
            isPartialEstimate: isPartial
        )
    }

    private func cost(forModel model: String, totals: TokenTotals) -> Double {
        pricing.cost(
            forModel: model,
            inputTokens: totals.input,
            outputTokens: totals.output,
            cacheReadTokens: totals.cacheRead,
            cacheWriteTokens: totals.cacheWrite
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
    var cacheWrite: Int

    static let zero = TokenTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)

    mutating func add(_ other: TokenTotals) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
    }

    /// Keeps the larger of each field — for cumulative streaming chunks.
    mutating func takeMax(_ other: TokenTotals) {
        input = max(input, other.input)
        output = max(output, other.output)
        cacheRead = max(cacheRead, other.cacheRead)
        cacheWrite = max(cacheWrite, other.cacheWrite)
    }
}

private struct ParsedMessage {
    let day: String
    let model: String
    var totals: TokenTotals
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

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

// MARK: - Incremental cache

/// Caches per-file `(day, model) -> tokens` aggregations, invalidated by file
/// mtime + size. Window filtering happens at read time so the same cache serves
/// any `daysBack`.
public final class CostUsageCache: @unchecked Sendable {
    public static let shared = CostUsageCache()

    private struct Entry {
        let modDate: Date
        let fileSize: UInt64
        let value: [DayModelKey: TokenTotals]
        let isPartial: Bool
    }

    private static let maxEntries = 512

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var accessOrder: [String] = []

    public init() {}

    func cached(for path: String, modDate: Date, fileSize: UInt64) -> (totals: [DayModelKey: TokenTotals], isPartial: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.modDate == modDate, entry.fileSize == fileSize else {
            return nil
        }
        touchLocked(path)
        return (entry.value, entry.isPartial)
    }

    func store(
        path: String,
        modDate: Date,
        fileSize: UInt64,
        value: [DayModelKey: TokenTotals],
        isPartial: Bool
    ) {
        lock.lock()
        entries[path] = Entry(modDate: modDate, fileSize: fileSize, value: value, isPartial: isPartial)
        touchLocked(path)
        while accessOrder.count > Self.maxEntries, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    private func touchLocked(_ path: String) {
        if let idx = accessOrder.firstIndex(of: path) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(path)
    }
}

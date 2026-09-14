import ClaudeMeterCore
import CoreFoundation
import Darwin
import Foundation

public struct CodexCostScanResult: Sendable, Equatable {
    public let usage: CostUsageResult
    public let knownCostUsd: Double
    public let knownDailyCosts: [String: Double]
    public let unknownCostDays: Set<String>
    public let hasUnknownCosts: Bool
    public let usesStandardTierAssumption: Bool

    public init(
        usage: CostUsageResult, knownCostUsd: Double = 0,
        knownDailyCosts: [String: Double] = [:], unknownCostDays: Set<String> = [],
        hasUnknownCosts: Bool = false, usesStandardTierAssumption: Bool = false
    ) {
        self.usage = usage
        self.knownCostUsd = knownCostUsd
        self.knownDailyCosts = knownDailyCosts
        self.unknownCostDays = unknownCostDays
        self.hasUnknownCosts = hasUnknownCosts
        self.usesStandardTierAssumption = usesStandardTierAssumption
    }
}

/// On-demand, bounded local scans. No credentials, current config, or network
/// reads are needed to interpret historical usage. Call off the main actor.
public struct CodexCostScanner: Sendable {
    static let maximumFileEvents = 20_000
    static let maximumHomeEvents = 100_000
    static let maximumFiles = 2_048
    static let maximumLineBytes = 1_024 * 1_024
    static let maximumScanBytes: UInt64 = 256 * 1_024 * 1_024
    public init() {}

    public func scan(
        codexHomes: [URL], daysBack: Int = 7, now: Date = Date(), calendar: Calendar = .current
    ) -> CostUsageResult {
        scanReport(codexHomes: codexHomes, daysBack: daysBack, now: now, calendar: calendar).usage
    }

    public func scanReport(
        codexHomes: [URL], daysBack: Int = 7, now: Date = Date(), calendar: Calendar = .current
    ) -> CodexCostScanResult {
        let homes = codexHomes.dedupedByResolvedPath().map {
            $0.resolvingSymlinksInPath().standardizedFileURL
        }.sorted { $0.path < $1.path }
        let today = calendar.startOfDay(for: now)
        let first =
            calendar.date(byAdding: .day, value: -(max(1, min(daysBack, 366)) - 1), to: today)
            ?? today
        let firstDay = JournalReader.dayString(from: first, calendar: calendar)
        let lastDay = JournalReader.dayString(from: today, calendar: calendar)
        var partial = false
        var bytesRead: UInt64 = 0
        var allRows: [Row] = []
        for home in homes {
            if Task.isCancelled {
                partial = true
                break
            }
            let files = discover(home: home, partial: &partial)
            var sessions: [String: FileEvents] = [:]
            var identities = Set<String>()
            var eventCount = 0
            var retainedBytes = 0
            for file in files {
                if Task.isCancelled {
                    partial = true
                    break
                }
                guard bytesRead < Self.maximumScanBytes else {
                    partial = true
                    break
                }
                guard
                    let metadata = try? JournalReader.regularTranscriptMetadata(
                        at: file, fm: .default)
                else {
                    partial = true
                    continue
                }
                let identity = "\(metadata.identity.device):\(metadata.identity.inode)"
                guard identities.insert(identity).inserted else { continue }
                let fileBudget = min(32 * 1_024 * 1_024, Self.maximumScanBytes - bytesRead)
                let read = JournalReader.readRegularTranscript(
                    at: file, maxFullReadBytes: 32 * 1_024 * 1_024,
                    tailReadBytes: 16 * 1_024 * 1_024, maximumReadBytes: fileBudget)
                // A failed read can have consumed part of its allowance.
                bytesRead += read.map { UInt64($0.data.count) } ?? fileBudget
                guard let read else {
                    partial = true
                    continue
                }
                // A tail has no verified leaf identity or inherited baseline.
                // Do not mistake a large cumulative counter for new usage.
                guard read.baseOffset == 0 else {
                    partial = true
                    continue
                }
                var parsed = parse(read.data, calendar: calendar)
                parsed.partial = parsed.partial || read.isPartial || read.metadata != metadata
                partial = partial || parsed.partial
                guard parsed.events.count <= Self.maximumHomeEvents - eventCount,
                    parsed.accountedBytes <= 32 * 1_024 * 1_024 - retainedBytes
                else {
                    partial = true
                    break
                }
                eventCount += parsed.events.count
                retainedBytes += parsed.accountedBytes
                let key = parsed.sessionID.map { "session:" + $0 } ?? "file:" + file.path
                if let old = sessions[key] {
                    if parsed.events.starts(with: old.events), parsed.sameOwnership(as: old) {
                        sessions[key] = parsed
                    } else if !old.events.starts(with: parsed.events)
                        || !parsed.sameOwnership(as: old)
                    {
                        // Divergent copies cannot be summed safely without global
                        // request identities. Keep one complete stream as a floor.
                        partial = true
                        if parsed.events.count > old.events.count { sessions[key] = parsed }
                    }
                } else {
                    sessions[key] = parsed
                }
            }
            var rootEvaluations: [String: Evaluation] = [:]
            for key in sessions.keys.sorted() {
                guard let file = sessions[key], file.parentID == nil, !file.hasEmbeddedAncestor,
                    file.historyStartOrdinal == nil
                else { continue }
                let evaluated = evaluate(file, initialWatermark: .zero, ownedStart: nil)
                rootEvaluations[key] = evaluated
                partial = partial || evaluated.partial
                append(
                    evaluated.rows, to: &allRows, firstDay: firstDay, lastDay: lastDay,
                    partial: &partial)
            }
            for key in sessions.keys.sorted() {
                guard let file = sessions[key],
                    file.parentID != nil || file.hasEmbeddedAncestor
                        || file.historyStartOrdinal != nil
                else { continue }
                guard !file.invalidOwnership else {
                    partial = true
                    continue
                }
                var ownership = ownedSuffix(file)
                if ownership == nil, file.historyStartOrdinal == nil,
                    let parentID = file.parentID, let forkDate = file.forkDate,
                    let parent = sessions["session:" + parentID],
                    let evaluated = rootEvaluations["session:" + parentID], !evaluated.partial,
                    !parent.partial,
                    let baseline = parent.events.last(where: {
                        $0.date <= forkDate && $0.total != nil
                    })?.total,
                    let start = file.events.firstIndex(where: { event in
                        guard event.date >= forkDate, let total = event.total,
                            let last = event.last, total.contains(last)
                        else { return false }
                        return total.subtracting(last) == baseline
                    })
                {
                    // A parent snapshot alone cannot identify child-owned rows.
                    // Require an exact inherited baseline at the child boundary.
                    ownership = (start, baseline)
                }
                guard let ownership else {
                    partial = true
                    continue
                }
                let evaluated = evaluate(
                    file, initialWatermark: ownership.baseline, ownedStart: ownership.start)
                partial = partial || evaluated.partial
                append(
                    evaluated.rows, to: &allRows, firstDay: firstDay, lastDay: lastDay,
                    partial: &partial)
            }
        }
        return aggregate(allRows, partial: partial, homes: homes)
    }

    private func append(
        _ rows: [Row], to output: inout [Row], firstDay: String, lastDay: String,
        partial: inout Bool
    ) {
        for row in rows where row.day >= firstDay && row.day <= lastDay {
            guard output.count < Self.maximumHomeEvents else {
                partial = true
                return
            }
            output.append(row)
        }
    }

    private func discover(home: URL, partial: inout Bool) -> [URL] {
        var files: [URL] = []
        var visited = 0
        for name in ["sessions", "archived_sessions"] {
            let groupStart = files.count
            let root = home.appendingPathComponent(name, isDirectory: true)
            if JournalReader.isMissingPath(root, fm: .default) { continue }
            guard (try? JournalReader.isDirectory(root, fm: .default)) == true else {
                partial = true
                continue
            }
            var failed = false
            guard
                let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in
                        failed = true
                        return true
                    })
            else {
                partial = true
                continue
            }
            while let url = walker.nextObject() as? URL {
                visited += 1
                if Task.isCancelled || visited > 20_000 || files.count >= Self.maximumFiles {
                    partial = true
                    break
                }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                    let type = attributes[.type] as? FileAttributeType
                else {
                    partial = true
                    walker.skipDescendants()
                    continue
                }
                if type == .typeSymbolicLink {
                    partial = true
                    walker.skipDescendants()
                } else if type == .typeDirectory {
                    if walker.level > 12 {
                        partial = true
                        walker.skipDescendants()
                    }
                } else if url.pathExtension == "jsonl" {
                    if type == .typeRegular { files.append(url) } else { partial = true }
                }
            }
            partial = partial || failed
            files[groupStart...].sort { $0.path < $1.path }
        }
        // Spend the bounded read allowance on active files before archives.
        return files
    }

    private func parse(_ data: Data, calendar: Calendar) -> FileEvents {
        var result = FileEvents()
        var model: String?
        var tier: String?
        var turnID: String?
        var retainedBytes = 0
        var start = data.startIndex
        while start < data.endIndex {
            if Task.isCancelled {
                result.partial = true
                break
            }
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { start = end == data.endIndex ? end : end + 1 }
            guard end > start else { continue }
            guard end - start <= Self.maximumLineBytes else {
                result.partial = true
                model = nil
                tier = nil
                continue
            }
            guard
                let object = try? JSONSerialization.jsonObject(with: data.subdata(in: start..<end))
                    as? [String: Any], let type = object["type"] as? String
            else {
                result.partial = true
                continue
            }
            let payload = object["payload"] as? [String: Any] ?? [:]
            if type == "session_meta" {
                let sessionID = string(payload, ["id", "session_id", "sessionId"])
                if !result.sawMetadata {
                    result.sessionID = sessionID
                    result.sawMetadata = true
                } else if sessionID != result.sessionID {
                    result.hasEmbeddedAncestor = true
                    continue
                }
                result.parentID =
                    string(
                        payload,
                        [
                            "forked_from_id", "forkedFromId", "parent_session_id",
                            "parentSessionId", "parent_thread_id",
                        ]) ?? result.parentID
                let parentKeys = [
                    "forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId",
                    "parent_thread_id",
                ]
                for key in parentKeys {
                    if let raw = payload[key], !(raw is NSNull), boundedString(raw) == nil,
                        (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) != ""
                    {
                        result.invalidOwnership = true
                    }
                }
                result.forkDate =
                    date(payload["timestamp"]) ?? date(object["timestamp"]) ?? result.forkDate
                result.historyStartOrdinal =
                    integer(payload["subagent_history_start_ordinal"])
                    ?? result.historyStartOrdinal
                if let raw = payload["subagent_history_start_ordinal"], !(raw is NSNull),
                    integer(raw) == nil
                {
                    result.invalidOwnership = true
                }
                if boundedString(payload["source"])?.lowercased() == "subagent" {
                    result.isSubagent = true
                }
                // A subagent with no explicit parent still needs an owned boundary.
                if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                    result.isSubagent = true
                    if result.parentID == nil, let subagent = source["subagent"] as? [String: Any],
                        let spawn = subagent["thread_spawn"] as? [String: Any]
                    {
                        result.parentID = string(spawn, ["parent_thread_id"])
                    }
                }
                continue
            }
            let info = payload["info"] as? [String: Any] ?? [:]
            if type == "turn_context" {
                let candidates = [
                    payload["model"], payload["model_name"], info["model"], info["model_name"],
                ]
                if candidates.contains(where: { $0 != nil }) {
                    model = candidates.compactMap { boundedString($0) }.first.map(
                        CodexCostPricing.normalizedModel)
                }
                tier = recordedTier(payload["service_tier"]) ?? recordedTier(info["service_tier"])
                turnID = string(payload, ["turn_id", "turnId"]) ?? turnID
                continue
            }
            guard type == "event_msg" else { continue }
            if payload["type"] as? String == "task_started" {
                let nextTurnID = string(payload, ["turn_id", "turnId"])
                let explicitTier = recordedTier(payload["service_tier"])
                // Keep explicit context evidence if this marker names that same
                // turn. A new or unidentified turn cannot inherit its tier.
                if nextTurnID == nil || nextTurnID != turnID {
                    tier = explicitTier
                } else if let explicitTier {
                    tier = explicitTier
                }
                turnID = nextTurnID
                continue
            }
            guard payload["type"] as? String == "token_count", !info.isEmpty else { continue }
            guard let timestamp = date(object["timestamp"]) else {
                result.partial = true
                continue
            }
            var invalid = false
            let total = counters(info["total_token_usage"], invalid: &invalid)
            let last = counters(info["last_token_usage"], invalid: &invalid)
            if invalid {
                result.partial = true
                continue
            }
            guard total != nil || last != nil else { continue }
            let eventModel =
                model ?? string(info, ["model", "model_name"])
                .map(CodexCostPricing.normalizedModel)
                ?? string(payload, ["model", "model_name"]).map(CodexCostPricing.normalizedModel)
                ?? "unknown-codex-model"
            let event = Event(
                date: timestamp, day: JournalReader.dayString(from: timestamp, calendar: calendar),
                model: eventModel,
                tier: recordedTier(info["service_tier"]) ?? recordedTier(payload["service_tier"])
                    ?? tier,
                turnID: string(payload, ["turn_id", "turnId"]) ?? turnID,
                responseID: string(info, ["response_id", "request_id"])
                    ?? string(payload, ["response_id", "request_id"]),
                ordinal: integer(object["ordinal"]), total: total, last: last)
            let identityBytes =
                (event.turnID?.utf8.count ?? 0) + (event.responseID?.utf8.count ?? 0)
            let eventBytes =
                192 + event.model.utf8.count + (event.tier?.utf8.count ?? 0) + identityBytes
            guard result.events.count < Self.maximumFileEvents,
                eventBytes <= 8 * 1_024 * 1_024 - retainedBytes
            else {
                result.partial = true
                break
            }
            retainedBytes += eventBytes
            result.accountedBytes = retainedBytes
            result.events.append(event)
        }
        if result.isSubagent, result.parentID == nil, result.historyStartOrdinal == nil {
            result.hasEmbeddedAncestor = true
        }
        if result.invalidOwnership || !result.sawMetadata {
            result.partial = true
            result.invalidOwnership = true
            result.hasEmbeddedAncestor = true
        }
        return result
    }

    private func ownedSuffix(_ file: FileEvents) -> (start: Int, baseline: Counts)? {
        guard let ordinal = file.historyStartOrdinal,
            let index = file.events.firstIndex(where: { ($0.ordinal ?? -1) >= ordinal })
        else { return nil }
        let first = file.events[index]
        if let baseline = file.events[..<index].last(where: { $0.total != nil })?.total {
            if let total = first.total, total == first.last, !total.contains(baseline) {
                return (index, .zero)
            }
            return (index, baseline)
        }
        if let total = first.total, let last = first.last, total.contains(last) {
            return (index, total.subtracting(last))
        }
        if first.total == nil, first.last != nil { return (index, .zero) }
        return nil
    }

    private func evaluate(_ file: FileEvents, initialWatermark: Counts, ownedStart: Int?)
        -> Evaluation
    {
        var output = Evaluation(partial: file.partial || (file.isSubagent && ownedStart == nil))
        var watermark = initialWatermark
        var seenLast = Set<LastKey>()
        var seenResponseIDs = Set<String>()
        var responseCounts: [String: Counts] = [:]
        for (index, event) in file.events.enumerated() {
            if Task.isCancelled {
                output.partial = true
                break
            }
            if let ownedStart, index < ownedStart { continue }
            if let responseID = event.responseID, seenResponseIDs.contains(responseID) {
                if let last = event.last, let previous = responseCounts[responseID],
                    last != previous
                {
                    output.partial = true
                }
                if let total = event.total {
                    if !watermark.contains(total) { output.partial = true }
                    watermark = watermark.maximum(total)
                }
                continue
            }
            let delta: Counts
            let exact: Bool
            if let total = event.total {
                if !total.contains(watermark) {
                    // Copied inherited snapshots are expected before the leaf's
                    // first increment. Other regressions have ambiguous lineage.
                    if !initialWatermark.contains(total) { output.partial = true }
                }
                let growth = total.subtracting(watermark)
                watermark = watermark.maximum(total)
                if let last = event.last {
                    delta = growth.minimum(last)
                    exact = delta == last
                    if !last.contains(growth) { output.partial = true }
                } else {
                    delta = growth
                    exact = false
                }
            } else if let last = event.last {
                if file.parentID != nil, ownedStart == nil {
                    output.partial = true
                    continue
                }
                let key = LastKey(
                    turnID: event.responseID == nil ? event.turnID : nil,
                    model: event.responseID == nil ? event.model : "",
                    responseID: event.responseID, counts: event.responseID == nil ? last : .zero)
                guard seenLast.insert(key).inserted else {
                    output.partial = true
                    continue
                }
                if event.responseID == nil { output.partial = true }
                delta = last
                exact = true
                guard let next = watermark.adding(last) else {
                    output.partial = true
                    continue
                }
                watermark = next
            } else {
                continue
            }
            if let responseID = event.responseID {
                seenResponseIDs.insert(responseID)
                responseCounts[responseID] = event.last
            }
            guard delta.input > 0 || delta.output > 0 else { continue }
            guard delta.cached <= delta.input, delta.write <= delta.input - delta.cached else {
                output.partial = true
                continue
            }
            let estimate =
                exact
                ? CodexCostPricing.estimate(
                    model: event.model, inputTokens: delta.input, cachedInputTokens: delta.cached,
                    cacheWriteInputTokens: delta.write, outputTokens: delta.output,
                    serviceTier: event.tier) : nil
            output.rows.append(
                Row(
                    day: event.day, model: event.model, counts: delta,
                    cost: estimate?.costUsd,
                    assumesTier: estimate?.usesStandardTierAssumption ?? false))
        }
        return output
    }

    private func aggregate(_ rows: [Row], partial: Bool, homes: [URL]) -> CodexCostScanResult {
        var partial = partial
        var daily: [DayModelKey: Totals] = [:]
        var models: [String: Totals] = [:]
        var knownDaily: [String: Double] = [:]
        var unknownDays = Set<String>()
        var assumesTier = false
        for row in rows {
            let key = DayModelKey(day: row.day, model: row.model)
            var day = daily[key, default: Totals()]
            var model = models[row.model, default: Totals()]
            guard day.add(row), model.add(row) else {
                partial = true
                continue
            }
            daily[key] = day
            models[row.model] = model
            if let cost = row.cost {
                knownDaily[row.day, default: 0] += cost
            } else {
                unknownDays.insert(row.day)
            }
            assumesTier = assumesTier || row.assumesTier
        }
        let modelRows = models.keys.sorted().map { name in
            let value = models[name]!
            return ModelUsage(
                name: name, inputTokens: value.uncached, outputTokens: value.counts.output,
                cacheReadTokens: value.counts.cached, cacheWriteTokens: value.counts.write,
                costUsd: value.unknown ? nil : value.cost)
        }
        let dayRows = daily.keys.sorted { ($0.day, $0.model) < ($1.day, $1.model) }.map { key in
            let value = daily[key]!
            return DailyModelUsage(
                day: key.day, model: key.model, inputTokens: value.uncached,
                outputTokens: value.counts.output, cacheReadTokens: value.counts.cached,
                cacheWriteTokens: value.counts.write, costUsd: value.unknown ? nil : value.cost)
        }
        return CodexCostScanResult(
            usage: CostUsageResult(
                models: modelRows, daily: dayRows, isPartialEstimate: partial,
                sourcePaths: homes.map(\.path)),
            knownCostUsd: knownDaily.values.reduce(0, +), knownDailyCosts: knownDaily,
            unknownCostDays: unknownDays, hasUnknownCosts: !unknownDays.isEmpty,
            usesStandardTierAssumption: assumesTier)
    }

    private func boundedString(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= 512 else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func recordedTier(_ raw: Any?) -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        return boundedString(raw) ?? "unknown-service-tier"
    }

    private func string(_ object: [String: Any], _ keys: [String]) -> String? {
        keys.compactMap { boundedString(object[$0]) }.first
    }

    private func date(_ value: Any?) -> Date? {
        guard let string = boundedString(value), let date = JournalReader.parseTimestamp(string),
            PersistedDateBounds.contains(date)
        else { return nil }
        return date
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let result = Int(number.stringValue), result >= 0
        else { return nil }
        return result
    }

    private func counters(_ raw: Any?, invalid: inout Bool) -> Counts? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any] else {
            invalid = true
            return nil
        }
        func count(_ key: String) -> Int {
            guard let raw = object[key] else { return 0 }
            guard let value = integer(raw) else {
                invalid = true
                return 0
            }
            return value
        }
        let value = Counts(
            input: count("input_tokens"),
            cached: max(count("cached_input_tokens"), count("cache_read_input_tokens")),
            write: count("cache_creation_input_tokens"), output: count("output_tokens"))
        // Validate optional subsets even though reasoning never adds to output.
        if object["reasoning_output_tokens"] != nil, count("reasoning_output_tokens") > value.output
        {
            invalid = true
        }
        if value.cached > value.input || value.write > value.input - min(value.cached, value.input)
        {
            invalid = true
        }
        return value
    }
}

extension CodexCostScanner {
    fileprivate struct Counts: Equatable, Hashable {
        var input: Int
        var cached: Int
        var write: Int
        var output: Int
        static let zero = Counts(input: 0, cached: 0, write: 0, output: 0)
        func contains(_ other: Self) -> Bool {
            input >= other.input && cached >= other.cached && write >= other.write
                && output >= other.output
        }
        func subtracting(_ other: Self) -> Self {
            Self(
                input: max(0, input - other.input), cached: max(0, cached - other.cached),
                write: max(0, write - other.write), output: max(0, output - other.output))
        }
        func minimum(_ other: Self) -> Self {
            Self(
                input: min(input, other.input), cached: min(cached, other.cached),
                write: min(write, other.write), output: min(output, other.output))
        }
        func maximum(_ other: Self) -> Self {
            Self(
                input: max(input, other.input), cached: max(cached, other.cached),
                write: max(write, other.write), output: max(output, other.output))
        }
        func adding(_ other: Self) -> Self? {
            let sums = [
                input.addingReportingOverflow(other.input),
                cached.addingReportingOverflow(other.cached),
                write.addingReportingOverflow(other.write),
                output.addingReportingOverflow(other.output),
            ]
            guard !sums.contains(where: \.overflow),
                !sums[0].partialValue.addingReportingOverflow(sums[3].partialValue).overflow
            else { return nil }
            return Self(
                input: sums[0].partialValue, cached: sums[1].partialValue,
                write: sums[2].partialValue, output: sums[3].partialValue)
        }
    }
    fileprivate struct Event: Equatable {
        let date: Date
        let day: String
        let model: String
        let tier: String?
        let turnID: String?
        let responseID: String?
        let ordinal: Int?
        let total: Counts?
        let last: Counts?
    }
    fileprivate struct FileEvents {
        var sessionID: String?
        var parentID: String?
        var forkDate: Date?
        var historyStartOrdinal: Int?
        var sawMetadata = false
        var hasEmbeddedAncestor = false
        var isSubagent = false
        var invalidOwnership = false
        var partial = false
        var accountedBytes = 0
        var events: [Event] = []
        func sameOwnership(as other: Self) -> Bool {
            parentID == other.parentID && historyStartOrdinal == other.historyStartOrdinal
                && hasEmbeddedAncestor == other.hasEmbeddedAncestor && forkDate == other.forkDate
                && invalidOwnership == other.invalidOwnership
        }
    }
    fileprivate struct LastKey: Hashable {
        let turnID: String?
        let model: String
        let responseID: String?
        let counts: Counts
    }
    fileprivate struct Row {
        let day: String
        let model: String
        let counts: Counts
        let cost: Double?
        let assumesTier: Bool
    }
    fileprivate struct Evaluation {
        var partial = false
        var rows: [Row] = []
    }
    fileprivate struct Totals {
        var counts = Counts.zero
        var cost = 0.0
        var unknown = false
        var uncached: Int { counts.input - counts.cached - counts.write }
        mutating func add(_ row: Row) -> Bool {
            guard let next = counts.adding(row.counts) else { return false }
            counts = next
            if let value = row.cost { cost += value } else { unknown = true }
            return true
        }
    }
}

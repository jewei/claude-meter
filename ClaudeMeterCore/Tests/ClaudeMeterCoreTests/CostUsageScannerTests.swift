import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("ModelPricing")
struct ModelPricingTests {
    @Test func matchesFamilyBySubstring() {
        let p = ModelPricing.current
        #expect(p.rate(forModel: "claude-opus-4-8") == p.rate(forModel: "OPUS"))
        #expect(p.rate(forModel: "claude-haiku-4-5").input == 1)
        // Unknown ids fall back to Sonnet pricing.
        #expect(p.rate(forModel: "mystery-model").input == 3)
    }

    @Test func computesCostPerMillionTokens() {
        let cost = ModelPricing.current.cost(
            forModel: "claude-sonnet-4-6",
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
        #expect(abs(cost - 3.0) < 0.0001)
    }

    @Test func fableHasItsOwnFallbackRateNotSonnet() {
        let r = ModelPricing.current.rate(forModel: "claude-fable-5")
        #expect(r.input == 10)
        #expect(r.output == 50)
        #expect(r.cacheRead == 1.0)
    }

    @Test func oneHourCacheWriteRateDerivesDoubleInputUnlessExplicit() {
        // Derived: models.dev only publishes the 5m rate, so catalog Rates carry nil.
        let derived = ModelPricing.Rate(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
        #expect(derived.resolvedCacheWrite1h == 10)
        // Explicit value wins when a source does provide one.
        let explicit = ModelPricing.Rate(
            input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWrite1h: 11)
        #expect(explicit.resolvedCacheWrite1h == 11)
    }
}

@Suite("ModelUsage.displayName")
struct ModelDisplayNameTests {
    @Test func formatsDashedVersion() {
        #expect(ModelUsage(name: "claude-opus-4-8").displayName == "Opus 4.8")
        #expect(ModelUsage(name: "claude-sonnet-4-6").displayName == "Sonnet 4.6")
    }

    @Test func skipsDateLikeTokens() {
        #expect(ModelUsage(name: "claude-3-5-sonnet-20241022").displayName == "Sonnet 3.5")
    }

    @Test func familyOnlyWhenNoVersion() {
        #expect(ModelUsage(name: "claude-opus").displayName == "Opus")
    }

    @Test func unknownFamilyReturnsRawId() {
        #expect(ModelUsage(name: "<synthetic>").displayName == "<synthetic>")
    }
}

@Suite("CostUsageScanner")
struct CostUsageScannerTests {
    /// Writes a transcript file under a fresh temp projects dir and returns the scanner.
    private func makeScanner(lines: [String]) throws -> (CostUsageScanner, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: file)
        // Fresh cache so cross-test state can't leak.
        let scanner = CostUsageScanner(projectsPath: root, cache: CostUsageCache())
        return (scanner, root)
    }

    private func assistantLine(
        id: String, requestId: String, model: String,
        input: Int, output: Int, ts: String
    ) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","requestId":"\(requestId)","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
    }

    private func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }

    @Test func dedupsCumulativeStreamingChunksByMaxNotSum() throws {
        let now = Date()
        let ts = iso(now)
        // Same id+requestId, cumulative usage: 100 then 250 input. Expect 250, not 350.
        let (scanner, root) = try makeScanner(lines: [
            assistantLine(
                id: "m1", requestId: "r1", model: "claude-sonnet-4-6", input: 100, output: 10,
                ts: ts),
            assistantLine(
                id: "m1", requestId: "r1", model: "claude-sonnet-4-6", input: 250, output: 40,
                ts: ts),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = scanner.scan(daysBack: 7, now: now)
        let sonnet = try #require(result.models.first { $0.name == "claude-sonnet-4-6" })
        #expect(sonnet.inputTokens == 250)
        #expect(sonnet.outputTokens == 40)
    }

    @Test func aggregatesPerModelAndTotalsCost() throws {
        let now = Date()
        let ts = iso(now)
        let (scanner, root) = try makeScanner(lines: [
            assistantLine(
                id: "a", requestId: "1", model: "claude-opus-4-8", input: 1_000_000, output: 0,
                ts: ts),
            assistantLine(
                id: "b", requestId: "2", model: "claude-sonnet-4-6", input: 1_000_000, output: 0,
                ts: ts),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = scanner.scan(daysBack: 7, now: now)
        #expect(result.models.count == 2)
        // Sorted by cost desc → Opus ($5) first.
        #expect(result.models.first?.name == "claude-opus-4-8")
        let totalCost = result.models.compactMap(\.costUsd).reduce(0, +)
        #expect(abs(totalCost - 8.0) < 0.001)  // 5 (opus) + 3 (sonnet)
    }

    @Test func ignoresEntriesOutsideWindow() throws {
        let now = Date()
        let old = iso(now.addingTimeInterval(-30 * 24 * 3600))
        let (scanner, root) = try makeScanner(lines: [
            assistantLine(
                id: "old", requestId: "1", model: "claude-sonnet-4-6", input: 1_000_000, output: 0,
                ts: old)
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        // File mtime is "now" so it's scanned, but the entry's timestamp is 30 days old.
        let result = scanner.scan(daysBack: 7, now: now)
        #expect(result.isEmpty)
    }

    /// Appends `lines` to an existing transcript on their own lines.
    private func append(_ lines: [String], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + lines.joined(separator: "\n")).utf8))
    }

    @Test("Incremental resume after append matches a full re-parse (no boundary double-count)")
    func incrementalResumeMatchesFullParse() throws {
        let now = Date()
        let ts = iso(now)
        let model = "claude-sonnet-4-6"
        // m0 is a finalized earlier message; m1 is the trailing in-flight message whose
        // chunks straddle the resume boundary on the next scan.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        try [
            assistantLine(id: "m0", requestId: "r0", model: model, input: 10, output: 1, ts: ts),
            assistantLine(id: "m1", requestId: "r1", model: model, input: 100, output: 10, ts: ts),
            assistantLine(id: "m1", requestId: "r1", model: model, input: 200, output: 20, ts: ts),
        ].joined(separator: "\n").data(using: .utf8)!.write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        // First scan seeds the cache; m1 is the pending (trailing) block.
        let cache = CostUsageCache()
        let scanner = CostUsageScanner(projectsPath: root, cache: cache)
        _ = scanner.scan(daysBack: 7, now: now)

        // Append m1's final chunk (cumulative 300) and a new message m2.
        try append(
            [
                assistantLine(id: "m1", requestId: "r1", model: model, input: 300, output: 30, ts: ts),
                assistantLine(id: "m2", requestId: "r2", model: model, input: 50, output: 5, ts: ts),
            ], to: file)

        let incremental = scanner.scan(daysBack: 7, now: now)

        // Independent from-scratch full parse of the final file.
        let full = CostUsageScanner(projectsPath: root, cache: CostUsageCache())
            .scan(daysBack: 7, now: now)

        let inc = try #require(incremental.models.first { $0.name == model })
        let ref = try #require(full.models.first { $0.name == model })
        // m0(10) + m1 max(300) + m2(50) = 360. A naive additive merge would over-count
        // m1 (200 + 300) and report 560.
        #expect(inc.inputTokens == 360)
        #expect(inc.inputTokens == ref.inputTokens)
        #expect(inc.outputTokens == ref.outputTokens)
    }

    @Test("Cache persists to disk and a fresh cache serves an unchanged file as an exact hit")
    func diskPersistenceRoundTrip() throws {
        let now = Date()
        let ts = iso(now)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        try assistantLine(
            id: "a", requestId: "1", model: "claude-opus-4-8", input: 1_000_000, output: 0, ts: ts)
            .data(using: .utf8)!.write(to: file)
        let diskURL = root.appendingPathComponent("cache.json")
        defer { try? FileManager.default.removeItem(at: root) }

        // Scan with a disk-backed cache, which flushes on completion.
        let first = CostUsageScanner(projectsPath: root, cache: CostUsageCache(persistenceURL: diskURL))
            .scan(daysBack: 7, now: now)
        #expect(FileManager.default.fileExists(atPath: diskURL.path))

        // A brand-new cache pointed at the same file must load the entry and serve the
        // unchanged transcript as an exact hit — no re-parse. Derive the path via
        // enumeration so it matches the canonical form the scanner (and thus the cache)
        // stores; on macOS temp dirs the manual `/var/...` path differs from `/private/var/...`.
        let canonical = try #require(
            FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "jsonl" })
        let attrs = try FileManager.default.attributesOfItem(atPath: canonical.path)
        let modDate = try #require(attrs[.modificationDate] as? Date)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let reloaded = CostUsageCache(persistenceURL: diskURL)
        guard case .exact(let value, _) = reloaded.lookup(
            path: canonical.path, modDate: modDate, fileSize: size)
        else {
            Issue.record("expected an exact cache hit after reload")
            return
        }
        let total = value.values.reduce(0) { $0 + $1.input }
        #expect(total == 1_000_000)
        #expect(first.models.first?.inputTokens == 1_000_000)
    }

    /// Assistant line with an explicit `cache_creation` breakdown alongside the
    /// legacy total, as Claude Code emits both today.
    private func cacheLine(
        id: String, model: String, legacyTotal: Int, fiveMinute: Int?, oneHour: Int?, ts: String
    ) -> String {
        let breakdown: String
        if fiveMinute != nil || oneHour != nil {
            breakdown =
                ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":\(fiveMinute ?? 0),\"ephemeral_1h_input_tokens\":\(oneHour ?? 0)}"
        } else {
            breakdown = ""
        }
        return """
            {"type":"assistant","timestamp":"\(ts)","requestId":"r-\(id)","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":\(legacyTotal)\(breakdown)}}}
            """
    }

    @Test("1h cache writes are priced at 2× input, not the 5m rate")
    func pricesOneHourCacheWritesAtDoubleInputRate() throws {
        let now = Date()
        let ts = iso(now)
        // Opus input $5/MTok → 1h cache-write $10/MTok; the 5m rate would be $6.25.
        let (scanner, root) = try makeScanner(lines: [
            cacheLine(
                id: "m1", model: "claude-opus-4-8", legacyTotal: 1_000_000,
                fiveMinute: 0, oneHour: 1_000_000, ts: ts)
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = scanner.scan(daysBack: 7, now: now)
        let opus = try #require(result.models.first { $0.name == "claude-opus-4-8" })
        #expect(opus.cacheWriteTokens == 1_000_000)  // display total stays combined
        #expect(abs((opus.costUsd ?? 0) - 10.0) < 0.001)
    }

    @Test("Mixed 5m/1h breakdown prices each tier separately")
    func pricesMixedCacheWriteTiers() throws {
        let now = Date()
        let ts = iso(now)
        // 1M at 5m ($6.25) + 1M at 1h ($10) = $16.25.
        let (scanner, root) = try makeScanner(lines: [
            cacheLine(
                id: "m1", model: "claude-opus-4-8", legacyTotal: 2_000_000,
                fiveMinute: 1_000_000, oneHour: 1_000_000, ts: ts)
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = scanner.scan(daysBack: 7, now: now)
        let opus = try #require(result.models.first { $0.name == "claude-opus-4-8" })
        #expect(opus.cacheWriteTokens == 2_000_000)
        #expect(abs((opus.costUsd ?? 0) - 16.25) < 0.001)
    }

    @Test("Legacy total without a breakdown keeps the 5m rate (older transcripts)")
    func legacyCacheTotalWithoutBreakdownUsesFiveMinuteRate() throws {
        let now = Date()
        let ts = iso(now)
        let (scanner, root) = try makeScanner(lines: [
            cacheLine(
                id: "m1", model: "claude-opus-4-8", legacyTotal: 1_000_000,
                fiveMinute: nil, oneHour: nil, ts: ts)
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = scanner.scan(daysBack: 7, now: now)
        let opus = try #require(result.models.first { $0.name == "claude-opus-4-8" })
        #expect(opus.cacheWriteTokens == 1_000_000)
        #expect(abs((opus.costUsd ?? 0) - 6.25) < 0.001)
    }

    @Test("Subagent transcripts under <session>/subagents/ are counted")
    func countsSubagentTranscripts() throws {
        let now = Date()
        let ts = iso(now)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("p", isDirectory: true)
        let subagents = project
            .appendingPathComponent("session-uuid", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try fm.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try assistantLine(
            id: "top", requestId: "r1", model: "claude-opus-4-8", input: 1_000_000, output: 0,
            ts: ts
        ).data(using: .utf8)!.write(to: project.appendingPathComponent("session-uuid.jsonl"))
        try assistantLine(
            id: "sub", requestId: "r2", model: "claude-opus-4-8", input: 2_000_000, output: 0,
            ts: ts
        ).data(using: .utf8)!.write(to: subagents.appendingPathComponent("agent-abc123.jsonl"))

        let result = CostUsageScanner(projectsPath: root, cache: CostUsageCache())
            .scan(daysBack: 7, now: now)
        let opus = try #require(result.models.first { $0.name == "claude-opus-4-8" })
        #expect(opus.inputTokens == 3_000_000)  // top-level + subagent
    }

    @Test("Context-fork subagent transcripts (acompact/aside_question) are skipped")
    func skipsContextForkSubagentTranscripts() throws {
        let now = Date()
        let ts = iso(now)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let subagents = root
            .appendingPathComponent("p", isDirectory: true)
            .appendingPathComponent("session-uuid", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try fm.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Fork files replay the parent's history verbatim (same usage blocks) —
        // counting them would double-bill. A plain agent file still counts.
        for name in ["agent-acompact-x.jsonl", "agent-aside_question-y.jsonl"] {
            try assistantLine(
                id: "fork-\(name)", requestId: "r", model: "claude-opus-4-8",
                input: 1_000_000, output: 0, ts: ts
            ).data(using: .utf8)!.write(to: subagents.appendingPathComponent(name))
        }
        try assistantLine(
            id: "plain", requestId: "r", model: "claude-opus-4-8", input: 500_000, output: 0,
            ts: ts
        ).data(using: .utf8)!.write(to: subagents.appendingPathComponent("agent-plain.jsonl"))

        let result = CostUsageScanner(projectsPath: root, cache: CostUsageCache())
            .scan(daysBack: 7, now: now)
        let opus = try #require(result.models.first { $0.name == "claude-opus-4-8" })
        #expect(opus.inputTokens == 500_000)  // fork files excluded
    }

    @Test("A cancelled task stops the scan early and marks the result partial")
    func cancelledTaskStopsScanEarly() async throws {
        let now = Date()
        let ts = iso(now)
        let (scanner, root) = try makeScanner(lines: [
            assistantLine(
                id: "m1", requestId: "r1", model: "claude-opus-4-8", input: 1_000_000, output: 0,
                ts: ts)
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let task = Task.detached { () -> CostUsageResult in
            // Deterministic: only start scanning once cancellation is guaranteed.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            return scanner.scan(daysBack: 7, now: now)
        }
        task.cancel()
        let result = await task.value
        #expect(result.isEmpty)
        #expect(result.isPartialEstimate)  // honest: totals were cut short
    }

    @Test func unionsMultipleProjectRootsAndIgnoresUnreadableRoot() throws {
        let now = Date()
        let ts = iso(now)
        let fm = FileManager.default

        func makeRoot(input: Int) throws -> URL {
            let root = fm.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            let project = root.appendingPathComponent("p", isDirectory: true)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            let line = assistantLine(
                id: UUID().uuidString, requestId: "r", model: "claude-opus-4-8",
                input: input, output: 0, ts: ts)
            try Data(line.utf8).write(to: project.appendingPathComponent("s.jsonl"))
            return root
        }

        let rootA = try makeRoot(input: 1_000_000)
        let rootB = try makeRoot(input: 1_000_000)
        let missing = fm.temporaryDirectory.appendingPathComponent("missing-" + UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootA)
            try? fm.removeItem(at: rootB)
        }

        // Two readable roots + one missing root: the missing root must not zero the
        // union (it `continue`s rather than `return .empty`).
        let scanner = CostUsageScanner(
            projectsPaths: [rootA, missing, rootB], cache: CostUsageCache())
        let result = scanner.scan(daysBack: 7, now: now)
        let opus = try #require(result.models.first { $0.name == "claude-opus-4-8" })
        #expect(opus.inputTokens == 2_000_000)  // summed across both readable roots
    }
}

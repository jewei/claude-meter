import Darwin
import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("Codex request pricing")
struct CodexCostPricingTests {
    @Test func publishedRatesAndAliases() throws {
        for model in ["gpt-6-astra", "openai/gpt-6-astra", "gpt-6-astra-2026-09-01"] {
            let price = try #require(
                CodexCostPricing.estimate(
                    model: model, inputTokens: 1000, cachedInputTokens: 300,
                    cacheWriteInputTokens: 200, outputTokens: 100, serviceTier: "standard"))
            #expect(abs(price.costUsd - 0.0128) < 1e-12)
            #expect(!price.usesStandardTierAssumption)
        }
        for model in ["gpt-5.6", "gpt-5.6-sol", "openai/gpt-5.6-sol"] {
            let price = try #require(
                CodexCostPricing.estimate(
                    model: model, inputTokens: 1000, cachedInputTokens: 300,
                    cacheWriteInputTokens: 200, outputTokens: 100))
            #expect(abs(price.costUsd - 0.00512) < 1e-12)
            #expect(price.usesStandardTierAssumption)
        }
    }

    @Test func thresholdPricesTheWholeRequestAndFastTier() throws {
        for input in [272_000, 272_001] {
            for model in ["gpt-6-astra", "gpt-5.6-sol"] {
                let standard = try #require(
                    CodexCostPricing.estimate(
                        model: model, inputTokens: input, cachedInputTokens: 100_000,
                        cacheWriteInputTokens: 100_000, outputTokens: 1000, serviceTier: "standard")
                )
                let rates = model == "gpt-6-astra" ? (10.0, 1.0, 12.5, 50.0) : (4.0, 0.4, 5.0, 20.0)
                let inputCost =
                    Double(input - 200_000) * rates.0 + 100_000 * rates.1 + 100_000 * rates.2
                let expected =
                    (inputCost * (input > 272_000 ? 2 : 1)
                        + 1000 * rates.3 * (input > 272_000 ? 1.5 : 1)) / 1_000_000
                #expect(abs(standard.costUsd - expected) < 1e-12)
                for tier in ["fast", "priority"] {
                    let fast = try #require(
                        CodexCostPricing.estimate(
                            model: model, inputTokens: input, cachedInputTokens: 100_000,
                            cacheWriteInputTokens: 100_000, outputTokens: 1000, serviceTier: tier))
                    #expect(abs(fast.costUsd - expected * 2) < 1e-12)
                }
            }
        }
    }

    @Test func refusesUnknownModelsTiersAndInvalidCounts() {
        for model in ["gpt-6", "other/gpt-6-astra", "gpt-6-astra-unknown", "claude-sonnet-4"] {
            #expect(CodexCostPricing.estimate(model: model, inputTokens: 1, outputTokens: 1) == nil)
        }
        #expect(
            CodexCostPricing.estimate(
                model: "gpt-6-astra", inputTokens: 1, outputTokens: 1, serviceTier: "unknown")
                == nil)
        #expect(
            CodexCostPricing.estimate(model: "gpt-6-astra", inputTokens: -1, outputTokens: 1) == nil
        )
        #expect(
            CodexCostPricing.estimate(
                model: "gpt-6-astra", inputTokens: 10, cachedInputTokens: 9,
                cacheWriteInputTokens: 2, outputTokens: 1) == nil)
    }
}

@Suite("Codex local costs")
struct CodexCostScannerTests {
    @Test func normalCumulativeRequestsAndRepeatedSnapshots() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/old/normal.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(1, total: 100, last: 100), fixture.event(2, total: 160, last: 60),
            ])
        let normal = fixture.scan()
        #expect(normal.usage.models.first?.inputTokens == 160)
        #expect(!normal.usage.isPartialEstimate)
        #expect(!normal.hasUnknownCosts)
        try fixture.write(
            "sessions/old/normal.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(1, total: 100, last: 100), fixture.event(2, total: 100, last: 100),
                fixture.event(3, total: 130, last: 100),
            ])
        let repeated = fixture.scan()
        #expect(repeated.usage.models.first?.inputTokens == 130)
        #expect(!repeated.usage.isPartialEstimate)
        #expect(repeated.hasUnknownCosts)
        #expect(abs(repeated.knownCostUsd - 0.001) < 1e-12)
    }

    @Test func divergentTotalsKeepOnlyReportedRequests() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(1, total: 100, last: 100), fixture.event(2, total: 1000, last: 40),
                fixture.event(3, total: 1050, last: 50),
            ])
        let report = fixture.scan()
        #expect(report.usage.models.first?.inputTokens == 190)
        #expect(report.usage.isPartialEstimate)
        #expect(!report.hasUnknownCosts)
    }

    @Test func staleRegressionDoesNotResetTheWatermark() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(1, total: 100, last: 100), fixture.event(2, total: 98, last: 5),
                fixture.event(3, total: 105, last: 5),
            ])
        let report = fixture.scan()
        #expect(report.usage.models.first?.inputTokens == 105)
        #expect(report.usage.isPartialEstimate)
    }

    @Test func interleavedLineagesAndCounterResetsNeverRecountTheGap() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        for (totals, expected) in [
            ([100_000, 5000, 101_000, 6000, 102_000], 102_000),
            ([1000, 1200, 300, 800, 1500], 1500),
        ] {
            let events = totals.enumerated().map { fixture.event($0.offset + 1, total: $0.element) }
            try fixture.write("sessions/s.jsonl", [fixture.meta("s"), fixture.context()] + events)
            let report = fixture.scan()
            #expect(report.usage.models.first?.inputTokens == expected)
            #expect(report.usage.isPartialEstimate)
            #expect(report.hasUnknownCosts)
            #expect(report.knownCostUsd == 0)
        }
    }

    @Test func lastOnlyRepeatsNeedDistinctResponseIdentity() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(1, last: 20), fixture.event(2, last: 20),
            ])
        #expect(fixture.scan().usage.models.first?.inputTokens == 20)
        #expect(fixture.scan().usage.isPartialEstimate)
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(1, last: 20, responseID: "a"),
                fixture.event(2, last: 20, responseID: "b"),
            ])
        #expect(fixture.scan().usage.models.first?.inputTokens == 40)
        #expect(!fixture.scan().usage.isPartialEstimate)
    }

    @Test func modelSwitchKeepsCountersAndUsesHistoricalTier() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(tier: "priority"),
                fixture.event(1, total: 100, last: 100),
                fixture.context("gpt-5.6", tier: "standard"),
                fixture.event(2, total: 160, last: 60),
            ])
        let report = fixture.scan()
        #expect(report.usage.models.first(where: { $0.name == "gpt-6-astra" })?.inputTokens == 100)
        #expect(report.usage.models.first(where: { $0.name == "gpt-5.6-sol" })?.inputTokens == 60)
        #expect(abs(report.knownCostUsd - 0.00224) < 1e-12)
        #expect(!report.usesStandardTierAssumption)
    }

    @Test func cachedAndReasoningTokensRemainSubsets() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        let first = fixture.usage(input: 100, cached: 20, output: 10, reasoning: 4)
        let second = fixture.usage(input: 160, cached: 40, output: 16, reasoning: 7)
        let last = fixture.usage(input: 60, cached: 20, output: 6, reasoning: 3)
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.rawEvent(1, total: first, last: first),
                fixture.rawEvent(2, total: second, last: last),
            ])
        let report = fixture.scan()
        let model = try #require(report.usage.models.first)
        #expect(model.inputTokens == 120)
        #expect(model.cacheReadTokens == 40)
        #expect(model.outputTokens == 16)
        let input = (model.inputTokens ?? 0) + (model.cacheReadTokens ?? 0)
        #expect(input + (model.outputTokens ?? 0) == 176)
        #expect(!report.usage.isPartialEstimate)
    }

    @Test func archivedPrefixExtendsActiveCopyWithoutDuplicatingIt() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        let prefix = [fixture.meta("s"), fixture.context(), fixture.event(1, total: 20, last: 20)]
        try fixture.write("sessions/2000/01/01/active.jsonl", prefix)
        try fixture.write(
            "archived_sessions/archive.jsonl", prefix + [fixture.event(2, total: 40, last: 20)])
        #expect(fixture.scan().usage.models.first?.inputTokens == 40)
        #expect(!fixture.scan().usage.isPartialEstimate)
        try fixture.write("sessions/2000/01/01/active.jsonl", [fixture.meta("s")])
        #expect(fixture.scan().usage.models.first?.inputTokens == 40)
    }

    @Test func resolvedForkSkipsCopiedParentPrefix() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/parent.jsonl",
            [
                fixture.meta("p"), fixture.context(),
                fixture.event(3, total: 100, last: 100),
            ])
        try fixture.write(
            "sessions/child.jsonl",
            [
                fixture.meta("c", parent: "p", forkSecond: 5), fixture.context(),
                fixture.event(1, total: 40), fixture.event(2, total: 100),
                fixture.event(6, total: 140, last: 40),
            ])
        let report = fixture.scan()
        #expect(report.usage.models.first?.inputTokens == 140)
        #expect(!report.usage.isPartialEstimate)
    }

    @Test func unresolvedForkNeverCountsInheritedCountersAsSpend() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/child.jsonl",
            [
                fixture.meta("c", parent: "missing", forkSecond: 5),
                fixture.context(), fixture.event(6, total: 1_000_000),
                fixture.event(7, total: 1_000_120, last: 120),
            ])
        let report = fixture.scan()
        #expect(report.usage.isEmpty)
        #expect(report.usage.isPartialEstimate)
    }

    @Test func parentSnapshotRequiresAnExactChildBoundaryAfterForkDate() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/p.jsonl",
            [
                fixture.meta("p"), fixture.context(), fixture.event(3, total: 100, last: 100),
            ])
        for childEvent in [
            fixture.event(4, total: 140, last: 40),
            fixture.event(6, total: 140, last: 30),
            fixture.event(6, total: 140),
        ] {
            try fixture.write(
                "sessions/c.jsonl",
                [
                    fixture.meta("c", parent: "p", forkSecond: 5), fixture.context(), childEvent,
                ])
            let report = fixture.scan()
            #expect(report.usage.models.first?.inputTokens == 100)
            #expect(report.usage.isPartialEstimate)
        }
    }

    @Test func historyOrdinalDoesNotUsePhysicalRecordPositions() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        var meta = fixture.meta("c", parent: "missing")
        var payload = try #require(meta["payload"] as? [String: Any])
        payload["subagent_history_start_ordinal"] = 2
        meta["payload"] = payload
        try fixture.write(
            "sessions/c.jsonl",
            [
                meta, fixture.context(), fixture.event(1, total: 1000),
                fixture.event(2, total: 1050, last: 50),
            ])
        let report = fixture.scan()
        #expect(report.usage.isEmpty)
        #expect(report.usage.isPartialEstimate)
    }

    @Test func explicitOwnedOrdinalWorksWithoutParentAndWithReset() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        var meta = fixture.meta("c", parent: "missing")
        var payload = try #require(meta["payload"] as? [String: Any])
        payload["subagent_history_start_ordinal"] = 10
        meta["payload"] = payload
        var prefix = fixture.event(1, total: 1000)
        prefix["ordinal"] = 2
        var owned = fixture.event(2, total: 1050, last: 50)
        owned["ordinal"] = 10
        try fixture.write("sessions/c.jsonl", [meta, fixture.context(), prefix, owned])
        #expect(fixture.scan().usage.models.first?.inputTokens == 50)
        #expect(!fixture.scan().usage.isPartialEstimate)
        owned = fixture.event(2, total: 50, last: 50)
        owned["ordinal"] = 10
        try fixture.write("sessions/c.jsonl", [meta, fixture.context(), prefix, owned])
        #expect(fixture.scan().usage.models.first?.inputTokens == 50)
        #expect(!fixture.scan().usage.isPartialEstimate)
    }

    @Test func homeAliasesDeduplicateButSeparateHomesRemainAdditive() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        let other = try CodexCostFixture()
        defer { other.remove() }
        let rows = [
            fixture.meta("same"), fixture.context(), fixture.event(1, total: 100, last: 100),
        ]
        try fixture.write("sessions/a.jsonl", rows)
        try other.write("sessions/b.jsonl", rows)
        let alias = fixture.home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)
        let result = CodexCostScanner().scan(
            codexHomes: [fixture.home, alias, other.home], now: fixture.now,
            calendar: fixture.calendar)
        #expect(result.models.first?.inputTokens == 200)
        #expect(result.sourcePaths.count == 2)
        #expect(CodexCostScanner().scan(codexHomes: [], now: fixture.now).isEmpty)
    }

    @Test func linksAndNonRegularTranscriptsAreExcluded() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "outside.jsonl", [fixture.context(), fixture.event(1, total: 100, last: 100)])
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent("sessions"),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("sessions/link.jsonl"),
            withDestinationURL: fixture.home.appendingPathComponent("outside.jsonl"))
        let fifo = fixture.home.appendingPathComponent("sessions/fifo.jsonl").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(fixture.scan().usage.isEmpty)
        #expect(fixture.scan().usage.isPartialEstimate)
    }

    @Test func invalidCountersDoNotTrapOrBecomeKnownZero() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        for invalid: Any in [-1, true, 1.5, "100", NSNumber(value: UInt64.max)] {
            try fixture.write(
                "sessions/s.jsonl",
                [
                    fixture.meta("s"), fixture.context(),
                    fixture.rawEvent(1, last: ["input_tokens": invalid, "output_tokens": 0]),
                ])
            #expect(fixture.scan().usage.isEmpty)
            #expect(fixture.scan().usage.isPartialEstimate)
        }
    }

    @Test func unknownModelAndTotalsOnlyKeepKnownSubtotals() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(tier: nil),
                fixture.event(1, total: 100, last: 100), fixture.event(2, total: 200),
                fixture.context("unknown"), fixture.event(3, total: 300, last: 100),
            ])
        let report = fixture.scan()
        #expect(report.hasUnknownCosts)
        #expect(report.usesStandardTierAssumption)
        #expect(report.usage.models.allSatisfy { $0.costUsd == nil })
        #expect(abs(report.knownCostUsd - 0.001) < 1e-12)
        #expect(report.knownDailyCosts.count == 1)
        #expect(report.unknownCostDays.count == 1)
        #expect(!report.usage.isPartialEstimate)
    }

    @Test func requestsArePricedBeforeDayAggregation() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(1, total: 200_000, last: 200_000),
                fixture.event(2, total: 400_000, last: 200_000),
            ])
        #expect(abs(fixture.scan().knownCostUsd - 4) < 1e-12)
    }

    @Test func divergentArchiveCopiesAreNotSummed() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(1, total: 100, last: 100),
            ])
        try fixture.write(
            "archived_sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(1, total: 200, last: 200),
            ])
        let report = fixture.scan()
        #expect((report.usage.models.first?.inputTokens ?? 0) <= 200)
        #expect(report.usage.isPartialEstimate)
    }

    @Test func oldEventsSetBaselineBeforeDateFiltering() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/2000/old.jsonl",
            [
                fixture.meta("s"), fixture.context(),
                fixture.event(-10 * 86_400, total: 100, last: 100),
                fixture.event(1, total: 150, last: 50),
            ])
        #expect(fixture.scan().usage.models.first?.inputTokens == 50)
    }

    @Test func responseIdentityDeduplicatesMixedCounterShapes() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        let counted = fixture.event(1, total: 100, last: 100, responseID: "r")
        let replay = fixture.event(2, last: 100, responseID: "r")
        for events in [[counted, replay], [replay, counted]] {
            try fixture.write("sessions/s.jsonl", [fixture.meta("s"), fixture.context()] + events)
            let report = fixture.scan()
            #expect(report.usage.models.first?.inputTokens == 100)
            #expect(abs(report.knownCostUsd - 0.001) < 1e-12)
        }
    }

    @Test func zeroGrowthReplayStillRegistersItsResponseIdentity() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        for repeatedLast in [100, 120] {
            try fixture.write(
                "sessions/s.jsonl",
                [
                    fixture.meta("s"), fixture.context(),
                    fixture.event(1, total: 100, last: 100),
                    fixture.event(2, total: 100, last: 100, responseID: "r"),
                    fixture.event(3, last: repeatedLast, responseID: "r"),
                ])
            let report = fixture.scan()
            #expect(report.usage.models.first?.inputTokens == 100)
            #expect(report.usage.isPartialEstimate == (repeatedLast != 100))
        }
    }

    @Test func descriptorReadBudgetRejectsGrowthAfterDiscovery() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        let file = fixture.home.appendingPathComponent("growing.jsonl")
        try Data([1]).write(to: file)
        let old = try #require(try JournalReader.regularTranscriptMetadata(at: file, fm: .default))
        try Data(repeating: 1, count: 100).write(to: file)
        #expect(
            JournalReader.readRegularTranscript(
                at: file, maxFullReadBytes: 1000,
                tailReadBytes: 500, maximumReadBytes: old.fileSize) == nil)
        let exact = try #require(
            JournalReader.readRegularTranscript(
                at: file, maxFullReadBytes: 1000,
                tailReadBytes: 500, maximumReadBytes: 100))
        #expect(exact.data.count == 100)
    }

    @Test func sameTurnStartKeepsTierButNewTurnClearsIt() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        let sameTurn: [String: Any] = [
            "type": "event_msg", "timestamp": fixture.timestamp(1),
            "payload": ["type": "task_started", "turn_id": "turn"],
        ]
        let newTurn: [String: Any] = [
            "type": "event_msg", "timestamp": fixture.timestamp(3),
            "payload": ["type": "task_started", "turn_id": "other"],
        ]
        try fixture.write(
            "sessions/s.jsonl",
            [
                fixture.meta("s"), fixture.context(tier: "priority"),
                sameTurn, fixture.event(2, total: 100, last: 100),
                newTurn, fixture.event(4, total: 200, last: 100),
            ])
        let report = fixture.scan()
        #expect(abs(report.knownCostUsd - 0.003) < 1e-12)
        #expect(report.usesStandardTierAssumption)
    }

    @Test func subagentSourceAndMalformedParentCannotBecomeRootUsage() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        for source: Any in ["subagent", ["subagent": "review"]] {
            let meta: [String: Any] = [
                "type": "session_meta", "payload": ["id": "s", "source": source],
            ]
            try fixture.write(
                "sessions/s.jsonl",
                [meta, fixture.context(), fixture.event(1, total: 100, last: 100)])
            #expect(fixture.scan().usage.isEmpty)
            #expect(fixture.scan().usage.isPartialEstimate)
        }
        let invalidParent: [String: Any] = [
            "type": "session_meta",
            "payload": ["id": "s", "forked_from_id": String(repeating: "x", count: 513)],
        ]
        try fixture.write(
            "sessions/s.jsonl",
            [invalidParent, fixture.context(), fixture.event(1, total: 100, last: 100)])
        #expect(fixture.scan().usage.isEmpty)
        #expect(fixture.scan().usage.isPartialEstimate)
    }

    @Test func tailWithoutLeafMetadataCannotClaimCumulativeUsage() throws {
        let fixture = try CodexCostFixture()
        defer { fixture.remove() }
        try fixture.write("sessions/s.jsonl", [fixture.meta("s"), fixture.context()])
        let file = fixture.home.appendingPathComponent("sessions/s.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 33 * 1_024 * 1_024)
        try handle.seekToEnd()
        var tail = Data([0x0A])
        tail.append(
            try JSONSerialization.data(
                withJSONObject: fixture.event(1, total: 1_000_000, last: 100)))
        tail.append(0x0A)
        try handle.write(contentsOf: tail)
        #expect(fixture.scan().usage.isEmpty)
        #expect(fixture.scan().usage.isPartialEstimate)
    }
}

private struct CodexCostFixture {
    let home: URL
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { base.addingTimeInterval(3600) }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-cost-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
    func scan() -> CodexCostScanResult {
        CodexCostScanner().scanReport(codexHomes: [home], now: now, calendar: calendar)
    }
    func timestamp(_ second: Int) -> String {
        ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(second)))
    }
    func meta(_ id: String, parent: String? = nil, forkSecond: Int = 0) -> [String: Any] {
        var payload: [String: Any] = ["id": id, "timestamp": timestamp(forkSecond)]
        if let parent { payload["forked_from_id"] = parent }
        return ["type": "session_meta", "payload": payload]
    }
    func context(_ model: String = "gpt-6-astra", tier: String? = "standard") -> [String: Any] {
        var payload: [String: Any] = ["model": model, "turn_id": "turn"]
        if let tier { payload["service_tier"] = tier }
        return ["type": "turn_context", "timestamp": timestamp(0), "payload": payload]
    }
    func usage(input: Int, cached: Int = 0, output: Int = 0, reasoning: Int = 0) -> [String: Any] {
        [
            "input_tokens": input, "cached_input_tokens": cached,
            "output_tokens": output, "reasoning_output_tokens": reasoning,
        ]
    }
    func event(_ second: Int, total: Int? = nil, last: Int? = nil, responseID: String? = nil)
        -> [String: Any]
    {
        rawEvent(
            second, total: total.map { usage(input: $0) }, last: last.map { usage(input: $0) },
            responseID: responseID)
    }
    func rawEvent(
        _ second: Int, total: [String: Any]? = nil, last: [String: Any]? = nil,
        responseID: String? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [:]
        if let total { info["total_token_usage"] = total }
        if let last { info["last_token_usage"] = last }
        if let responseID { info["response_id"] = responseID }
        return [
            "type": "event_msg", "timestamp": timestamp(second),
            "payload": ["type": "token_count", "info": info],
        ]
    }
    func write(_ path: String, _ rows: [[String: Any]]) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: url)
    }
}

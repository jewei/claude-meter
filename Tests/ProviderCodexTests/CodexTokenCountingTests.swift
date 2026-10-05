import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderCodex
import Testing

/// The Codex counting rules inside one session: cumulative counters, restarts, response
/// IDs, and events with only `last_token_usage`.
@Suite struct CodexTokenCountingTests: CodexRolloutTesting {
    let calendar = Calendar.fixed("UTC")

    @Test func cumulativeCountersAndArchivedCopiesCountOnceAcrossMidnight() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let first = event(
            total: (100, 10), last: (100, 10), at: .reference(-.days(1)), id: "one")
        let second = event(total: (160, 16), last: (60, 6), id: "two")
        let log = try json(metadata("session"), first, second, second)
        try home.write(log, to: "sessions/2026/10/04/rollout-a.jsonl")
        try home.write(log, to: "archived_sessions/rollout-a.jsonl")
        let result = try await history(["home": home])
        #expect(result.provider == .codex)
        #expect(result.source == .thisMac)
        #expect(tokens(result) == 66)
        #expect(tokens(result, "home", .yesterday) == 110)
        #expect(!result.history(for: "home").isPartial)
    }

    @Test func cacheWriteTokensArePartOfInput() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        // Upstream Codex fills cached_input_tokens and cache_write_input_tokens from the
        // Responses API input_tokens_details, so both are parts of input_tokens.
        let line = event(
            total: (100, 10), last: (100, 10),
            extra: ["cached_input_tokens": 40, "cache_write_input_tokens": 60])
        try home.write(try json(metadata("session"), line), to: "sessions/a.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 110)
    }

    @Test func repeatedCountersWithoutResponseIDsAreNotPartial() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let repeated = event(total: (100, 10), last: (100, 10), id: nil)
        try home.write(try json(metadata("session"), repeated, repeated), to: "sessions/a.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 110)
        #expect(!result.history(for: "home").isPartial)
    }

    @Test func nullInfoAndOtherLinesAreIgnored() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let log = try json(
            metadata("session"),
            [
                "type": "event_msg", "timestamp": Date.reference().ISO8601Format(),
                "payload": ["type": "token_count", "info": NSNull()],
            ],
            ["type": "response_item", "payload": ["type": "message", "content": "secret"]],
            ["type": "turn_context", "payload": ["turn_id": "t1"]],
            event(total: (10, 1), last: (10, 1), id: "one"))
        try home.write(log, to: "sessions/a.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 11)
        #expect(!result.history(for: "home").isPartial)
    }

    /// CDX-12: counters that restart inside one file (a resumed session) still count. A
    /// restart seen at its first response is exact.
    @Test func countersThatRestartInsideAFileStillCount() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let log = try json(
            metadata("session"), event(total: (100, 10), last: (100, 10), id: "a"),
            event(total: (10, 1), last: (10, 1), id: "b"),
            event(total: (30, 3), last: (20, 2), id: "c"))
        try home.write(log, to: "sessions/a.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 143)
        #expect(!result.history(for: "home").isPartial)
    }

    @Test func aRestartFoundLateCountsTheEventAndIsPartial() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let log = try json(
            metadata("session"), event(total: (100, 10), last: (100, 10), id: "a"),
            event(total: (30, 3), last: (20, 2), id: "b"))
        try home.write(log, to: "sessions/a.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 132)
        #expect(result.history(for: "home").isPartial)
    }

    @Test func lastOnlyEventsCountOncePerTurnResponseAndValue() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let withIDs = try json(
            metadata("ids"), event(total: nil, last: (10, 1), id: "r1"),
            event(total: nil, last: (10, 1), id: "r1"), event(total: nil, last: (20, 2), id: "r2"))
        try home.write(withIDs, to: "sessions/ids.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 33)
        #expect(!result.history(for: "home").isPartial)

        let other = try TemporaryDirectory()
        defer { other.remove() }
        let repeated = event(total: nil, last: (10, 1), id: nil)
        try other.write(try json(metadata("plain"), repeated, repeated), to: "sessions/a.jsonl")
        let plain = try await history(["home": other])
        #expect(tokens(plain) == 11)
        #expect(plain.history(for: "home").isPartial)
    }

    @Test func aRepeatedResponseWithOtherUsageCountsOnceAndIsPartial() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let log = try json(
            metadata("session"), event(total: (100, 10), last: (100, 10), id: "r"),
            event(total: (150, 15), last: (50, 5), id: "r"))
        try home.write(log, to: "sessions/a.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 110)
        #expect(result.history(for: "home").isPartial)
    }
}

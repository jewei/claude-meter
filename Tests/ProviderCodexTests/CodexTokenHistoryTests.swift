import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderCodex
import Testing

/// Codex rollout files, read from synthetic Codex homes. Scans run one at a time because they
/// share the process-wide `BlockingIO` pool with other suites.
@Suite(.serialized) struct CodexTokenHistoryTests {
    private let calendar = Calendar.fixed("UTC")

    private func json(_ objects: [String: Any]...) throws -> String {
        try objects.map { object in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self) + "\n"
        }.joined()
    }

    private func metadata(
        _ id: String, parent: String? = nil, ordinal: Any? = nil, extra: [String: Any] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": id, "timestamp": Date.reference(-5).ISO8601Format(), "cwd": "/secret/path",
        ]
        payload["forked_from_id"] = parent
        payload["subagent_history_start_ordinal"] = ordinal
        payload.merge(extra) { _, new in new }
        return [
            "type": "session_meta", "timestamp": Date.reference(-5).ISO8601Format(),
            "payload": payload,
        ]
    }

    /// A `token_count` event with cumulative `total` and per-response `last` usage.
    private func event(
        total: (Int, Int)?, last: (Int, Int)?, at date: Date = .reference(),
        ordinal: Int = 0, id: String? = "response", extra: [String: Any] = [:]
    ) -> [String: Any] {
        func usage(_ counts: (Int, Int)) -> [String: Any] {
            [
                "input_tokens": counts.0, "output_tokens": counts.1,
                "cached_input_tokens": counts.0 / 2, "reasoning_output_tokens": counts.1 / 2,
                "total_tokens": counts.0 + counts.1,
            ].merging(extra) { _, new in new }
        }
        var info: [String: Any] = [:]
        info["total_token_usage"] = total.map(usage)
        info["last_token_usage"] = last.map(usage)
        info["response_id"] = id
        return [
            "type": "event_msg", "timestamp": date.ISO8601Format(), "ordinal": ordinal,
            "payload": ["type": "token_count", "info": info],
        ]
    }

    private func history(_ homes: [String: TemporaryDirectory]) async throws
        -> ProviderTokenHistory
    {
        let roots = homes.map { HistoryRoot(account: AccountID($0.key), directory: $0.value.url) }
        return try await CodexTokenHistory(roots: { roots }, calendar: calendar)
            .history(now: .reference())
    }

    private func tokens(
        _ history: ProviderTokenHistory, _ account: AccountID = "home",
        _ period: TokenPeriod = .today
    ) -> Int64? {
        history.history(for: account).tokens(in: period, now: .reference(), calendar: calendar)
    }

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

    @Test func aSubagentCountsOnlyTheHistoryAfterItsOrdinal() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let inherited = event(total: (100, 10), last: (100, 10), ordinal: 10, id: "parent")
        let owned = event(total: (150, 15), last: (50, 5), ordinal: 50, id: "child")
        try home.write(try json(metadata("parent"), inherited), to: "sessions/parent.jsonl")
        let source = ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]]
        try home.write(
            try json(
                metadata("child", ordinal: 50, extra: ["source": source]), metadata("parent"),
                inherited, owned),
            to: "sessions/child.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 165)
        #expect(!result.history(for: "home").isPartial)
    }

    @Test func aForkWithoutAnOrdinalStartsWhereItsCountersContinueTheParent() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let before = event(total: (100, 10), last: (100, 10), at: .reference(-60), id: "p")
        try home.write(try json(metadata("parent"), before), to: "sessions/parent.jsonl")
        let copied = event(total: (100, 10), last: (100, 10), at: .reference(-60), id: "p")
        let owned = event(total: (150, 15), last: (50, 5), at: .reference(-1), id: "c")
        try home.write(
            try json(metadata("fork", parent: "parent"), copied, owned), to: "sessions/fork.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == Int64(110 + 55))
        #expect(!result.history(for: "home").isPartial)
    }

    @Test func anUnresolvedForkCountsNothingAndIsPartial() async throws {
        let home = try TemporaryDirectory()
        let other = try TemporaryDirectory()
        defer {
            home.remove()
            other.remove()
        }
        let inherited = event(total: (1_000, 100), last: (10, 1), id: "inherited")
        try home.write(
            try json(metadata("orphan", parent: "missing"), inherited),
            to: "sessions/orphan.jsonl")
        // This parent lives in another account's home, which this account never reads.
        try home.write(
            try json(metadata("fork", parent: "parent"), inherited), to: "sessions/fork.jsonl")
        try other.write(
            try json(metadata("parent"), event(total: (100, 10), last: (100, 10), id: "p")),
            to: "sessions/parent.jsonl")
        let result = try await history(["home": home, "other": other])
        #expect(tokens(result) == 0)
        #expect(result.history(for: "home").isPartial)
        #expect(tokens(result, "other") == 110)
        #expect(!result.history(for: "other").isPartial)
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

    @Test func conflictingCopiesKeepTheLongerCopyAndArePartial() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let one = event(total: (100, 10), last: (100, 10), id: "one")
        let two = event(total: (200, 20), last: (100, 10), id: "two")
        let other = event(total: (150, 15), last: (50, 5), id: "other")
        try home.write(try json(metadata("session"), one, two), to: "sessions/a.jsonl")
        try home.write(try json(metadata("session"), one, other, two), to: "sessions/b.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 220)
        #expect(result.history(for: "home").isPartial)
    }

    @Test func invalidOwnershipAndCountersArePartial() async throws {
        let cases: [String] = [
            try json(event(total: (100, 10), last: (100, 10))),
            try json(metadata("session", extra: ["parent_thread_id": 42])),
            try json(metadata("session", ordinal: -1)),
            try json(
                metadata("session"),
                event(total: (100, 10), last: nil, extra: ["input_tokens": true])),
            try json(
                metadata("session"),
                event(total: (100, 10), last: (100, 10), extra: ["output_tokens": 1.5])),
            try json(
                metadata("session"),
                [
                    "type": "event_msg", "timestamp": "never",
                    "payload": [
                        "type": "token_count",
                        "info": ["last_token_usage": ["input_tokens": 1, "output_tokens": 1]],
                    ],
                ]),
        ]
        for line in cases {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line, to: "sessions/a.jsonl")
            let result = try await history(["home": home])
            #expect(result.history(for: "home").isPartial, "\(line)")
            #expect((tokens(result) ?? 0) == 0, "\(line)")
        }
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

    @Test func eachHomeCountsOnlyItsOwnFolders() async throws {
        let personal = try TemporaryDirectory()
        let work = try TemporaryDirectory()
        defer {
            personal.remove()
            work.remove()
        }
        let line = event(total: (100, 10), last: (100, 10), id: "one")
        try personal.write(try json(metadata("a"), line), to: "sessions/a.jsonl")
        try personal.write(try json(metadata("b"), line), to: "archived_sessions/b.jsonl")
        try personal.write(try json(metadata("c"), line), to: "log/c.jsonl")
        try work.write(try json(metadata("d"), line), to: "sessions/d.jsonl")
        let result = try await history(["personal": personal, "work": work])
        #expect(tokens(result, "personal") == 220)
        #expect(tokens(result, "work") == 110)
        #expect(tokens(result, "missing") == nil)
    }
}

import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderCodex
import Testing

/// Codex rollout files, read from synthetic Codex homes. Each test has its own scanner and
/// folders, so the suite runs in parallel with the rest of the package.
@Suite struct CodexTokenHistoryTests: CodexRolloutTesting {
    let calendar = Calendar.fixed("UTC")

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

    /// A subagent whose counters restart at its ordinal owns its whole total.
    @Test func aSubagentWhoseCountersRestartAtItsOrdinalOwnsThem() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let inherited = event(total: (100, 10), last: (100, 10), ordinal: 10, id: "parent")
        try home.write(try json(metadata("parent"), inherited), to: "sessions/parent.jsonl")
        let source = ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]]
        try home.write(
            try json(
                metadata("child", ordinal: 50, extra: ["source": source]), metadata("parent"),
                inherited, event(total: (5, 1), last: (5, 1), ordinal: 50, id: "c1"),
                event(total: (15, 2), last: (10, 1), ordinal: 51, id: "c2")),
            to: "sessions/child.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == Int64(110 + 6 + 11))
        #expect(!result.history(for: "home").isPartial)
    }

    /// CDX-13: a subagent that names no parent and no ordinal (such as a review) starts its
    /// own history, so it owns all its events.
    @Test func aSubagentWithoutAParentOwnsItsEvents() async throws {
        let sources: [Any] = [
            ["subagent": "review"], "subagent", ["subagent": ["other": "memory"]],
            ["subagent": ["thread_spawn": ["depth": 1]]],
        ]
        for source in sources {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(
                try json(
                    metadata("review", extra: ["source": source]),
                    event(total: (50, 5), last: (50, 5), id: "r")),
                to: "sessions/review.jsonl")
            let result = try await history(["home": home])
            #expect(tokens(result) == 55, "\(source)")
            #expect(!result.history(for: "home").isPartial, "\(source)")
        }
    }

    /// CDX-10: when the homes cannot be resolved, the read fails and keeps its last value. It
    /// never scans no roots, which would discard the scan state.
    @Test func aFailedRootResolutionFailsTheRead() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let line = event(total: (100, 10), last: (100, 10), id: "one")
        try home.write(try json(metadata("session"), line), to: "sessions/a.jsonl")
        let failing = Locked(false)
        let roots = [HistoryRoot(account: "home", directory: home.url)]
        let source = CodexTokenHistory(
            roots: {
                if failing.value { throw ProviderError("The homes did not answer.") }
                return roots
            }, calendar: calendar)
        #expect(tokens(try await source.history(now: .reference(), previous: nil)) == 110)

        failing.withLock { $0 = true }
        await #expect(throws: ProviderError.self) {
            try await source.history(now: .reference(), previous: nil)
        }

        failing.withLock { $0 = false }
        #expect(tokens(try await source.history(now: .reference(), previous: nil)) == 110)
    }

    /// A fork without an ordinal needs valid parent counters to find its boundary.
    @Test func aParentWithInvalidCountersLeavesTheForkUnresolved() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let before = event(total: (100, 10), last: (100, 10), at: .reference(-60), id: "p")
        let broken = event(total: (120, 12), last: nil, extra: ["input_tokens": true])
        try home.write(try json(metadata("parent"), before, broken), to: "sessions/parent.jsonl")
        let owned = event(total: (150, 15), last: (50, 5), at: .reference(-1), id: "c")
        try home.write(
            try json(metadata("fork", parent: "parent"), before, owned), to: "sessions/fork.jsonl")
        let result = try await history(["home": home])
        #expect(tokens(result) == 110)
        #expect(result.history(for: "home").isPartial)
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

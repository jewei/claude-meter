import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderGrok
import Testing

/// Grok Build session updates, read from a synthetic Grok home. Each test makes and removes
/// its own home.
@Suite struct GrokTokenHistoryTests {
    private let calendar = Calendar.fixed("UTC")

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func usage(input: Any? = 1_000, output: Any? = 50) -> [String: Any] {
        var usage: [String: Any] = [
            "cachedReadTokens": 700, "cacheCreationTokens": 100, "reasoningTokens": 20,
        ]
        usage["inputTokens"] = input
        usage["outputTokens"] = output
        return usage
    }

    /// A completed turn in `params`, dated by `agentTimestampMs`.
    private func turn(
        _ eventID: String?, at date: Date = .reference(),
        models: [String: Any]? = nil, kind: String = "turn_completed"
    ) throws -> String {
        var meta: [String: Any] = ["agentTimestampMs": date.timeIntervalSince1970 * 1000]
        meta["eventId"] = eventID
        let update: [String: Any] = [
            "sessionUpdate": kind,
            "usage": ["modelUsage": models ?? ["unknown-model": usage()]],
        ]
        return try json([
            "jsonrpc": "2.0", "method": "session/update",
            "params": ["_meta": meta, "update": update, "sessionId": "s"],
        ])
    }

    private func history(_ home: TemporaryDirectory) async throws -> ProviderTokenHistory {
        try await GrokTokenHistory(
            roots: { [HistoryRoot(account: .default, directory: home.url)] }, calendar: calendar
        ).history(now: .reference())
    }

    private func tokens(
        _ history: ProviderTokenHistory, _ period: TokenPeriod = .today
    ) -> Int64? {
        history.history(for: .default).tokens(in: period, now: .reference(), calendar: calendar)
    }

    @Test func completedTurnsCountInputAndOutputOnceAcrossFiles() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let yesterday = Date.reference(-.days(1))
        try home.write(
            try turn("one") + turn("two", at: yesterday), to: "sessions/one/updates.jsonl")
        try home.write(try turn("one"), to: "sessions/child/updates.jsonl")
        try home.write(try turn("three"), to: "sessions/one/other.jsonl")
        let result = try await history(home)
        #expect(result.provider == .grok)
        #expect(result.source == .thisMac)
        #expect(tokens(result) == 1_050)
        #expect(tokens(result, .yesterday) == 1_050)
        #expect(!result.history(for: .default).isPartial)
    }

    @Test func eachModelOfATurnCountsAndTheLargerCopyWins() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let models: [String: Any] = [
            "model-a": usage(input: 10, output: 1), "model-b": usage(input: 20, output: nil),
        ]
        try home.write(try turn("one", models: models), to: "sessions/a/updates.jsonl")
        let larger: [String: Any] = ["model-a": usage(input: 15, output: 1)]
        try home.write(try turn("one", models: larger), to: "sessions/b/updates.jsonl")
        let result = try await history(home)
        #expect(tokens(result) == Int64(16 + 20))
    }

    @Test func topLevelUpdatesUseTheLineTimestamp() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let line = try json([
            "timestamp": Date.reference(-.days(1)).ISO8601Format(),
            "_meta": ["eventId": "top"],
            "update": [
                "sessionUpdate": "turn_completed",
                "usage": ["modelUsage": ["model": usage(input: "40", output: "2")]],
            ],
        ])
        try home.write(line, to: "sessions/a/updates.jsonl")
        let result = try await history(home)
        #expect(tokens(result, .yesterday) == 42)
        #expect(!result.history(for: .default).isPartial)
    }

    @Test func unfinishedTurnsAreAbsentNotPartial() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let lines = [
            try turn("chunk", kind: "agent_message_chunk"),
            try json(["params": ["update": ["sessionUpdate": "turn_completed"]]]),
            try json(["method": "session/prompt", "params": ["prompt": "secret text"]]),
        ]
        try home.write(lines.joined(), to: "sessions/a/updates.jsonl")
        let result = try await history(home)
        #expect(tokens(result) == nil)
        #expect(!result.history(for: .default).hasRecords)
        #expect(!result.history(for: .default).isPartial)
    }

    @Test func turnsThatCannotBeCountedMakeHistoryPartial() async throws {
        let cases: [(String, Int64)] = [
            ("{broken}\n", 0),
            (try turn(nil), 1_050),
            (try turn("bad-model", models: ["a": usage(input: true), "b": usage()]), 1_050),
            (try turn("not-object", models: ["a": "text", "b": usage()]), 1_050),
            (try turn("future", at: .reference(.hours(1))), 0),
            (
                try json([
                    "update": ["sessionUpdate": "turn_completed", "usage": ["modelUsage": [:]]]
                ]), 0
            ),
        ]
        for (line, expected) in cases {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let good = try turn("good", models: ["m": usage(input: 1, output: 1)])
            try home.write(line + good, to: "sessions/a/updates.jsonl")
            let result = try await history(home)
            #expect(tokens(result) == 2 + expected, "\(line)")
            #expect(result.history(for: .default).isPartial, "\(line)")
        }
    }
}

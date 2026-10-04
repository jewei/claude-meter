import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderClaude
import Testing

/// Claude Code session logs, read from synthetic config dirs.
@Suite struct ClaudeTokenHistoryTests {
    private let calendar = Calendar.fixed("UTC")

    /// One assistant line. Pass nil to leave a field out.
    private func assistant(
        _ id: String?, request: String? = "r", session: String? = nil, input: Any = 10,
        output: Any = 3,
        read: Any? = 7, write: Any? = 2, split: [String: Any]? = nil,
        date: Any = Date.reference().ISO8601Format(), type: String = "assistant"
    ) throws -> String {
        var usage: [String: Any] = ["input_tokens": input, "output_tokens": output]
        usage["cache_read_input_tokens"] = read
        usage["cache_creation_input_tokens"] = write
        usage["cache_creation"] = split
        var message: [String: Any] = [
            "model": "unknown-model", "usage": usage,
            "content": [["type": "text", "text": "secret prompt text"]],
        ]
        message["id"] = id
        var object: [String: Any] = ["type": type, "timestamp": date, "message": message]
        object["requestId"] = request
        object["sessionId"] = session
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func history(
        _ roots: [HistoryRoot], calendar: Calendar? = nil
    ) async throws -> ProviderTokenHistory {
        try await ClaudeTokenHistory(roots: { roots }, calendar: calendar ?? self.calendar)
            .history(now: .reference(), previous: nil)
    }

    private func tokens(
        _ history: ProviderTokenHistory, _ account: AccountID = "claude",
        _ period: TokenPeriod = .today, calendar: Calendar? = nil
    ) -> Int64? {
        history.history(for: account).tokens(
            in: period, now: .reference(), calendar: calendar ?? self.calendar)
    }

    @Test func streamedAndCopiedResponsesCountOnce() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let yesterday = Date.reference(-.days(1)).ISO8601Format()
        try home.write(
            try assistant("first", input: 10) + assistant("first", input: 20)
                + assistant("old", input: 30, date: yesterday),
            to: "projects/app/session.jsonl")
        try home.write(try assistant("first", input: 10), to: "projects/app/copy.jsonl")
        let result = try await history([HistoryRoot(account: "claude", directory: home.url)])
        #expect(result.provider == .claude)
        #expect(result.source == .thisMac)
        #expect(tokens(result) == 32)
        #expect(tokens(result, "claude", .yesterday) == 42)
        #expect(tokens(result, "claude", .lastSevenDays) == 74)
        #expect(!result.history(for: "claude").isPartial)
    }

    @Test func aCopyWithoutARequestIDCountsOnceAcrossSessions() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        // Older Claude Code wrote no request ID, and a resumed session copies the response.
        try home.write(
            try assistant("msg_1", request: nil, session: "s1"), to: "projects/a/s1.jsonl")
        try home.write(
            try assistant("msg_1", request: nil, session: "s2"), to: "projects/a/s2.jsonl")
        let result = try await history([HistoryRoot(account: "claude", directory: home.url)])
        #expect(tokens(result) == 22)
        #expect(!result.history(for: "claude").isPartial)
    }

    @Test func theSameTieRuleAppliesWithinAndAcrossFiles() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let lateYesterday = Date.reference(-.hours(12) - 60).ISO8601Format()
        let today = Date.reference().ISO8601Format()
        // Within one file: the larger count wins even when it comes first.
        try home.write(
            try assistant("shrunk", input: 30) + assistant("shrunk", input: 20),
            to: "projects/a/one.jsonl")
        // Equal counts: the earlier date wins, in either file order.
        try home.write(try assistant("copied", date: lateYesterday), to: "projects/a/a.jsonl")
        try home.write(try assistant("copied", date: today), to: "projects/a/b.jsonl")
        try home.write(try assistant("reverse", date: today), to: "projects/a/c.jsonl")
        try home.write(try assistant("reverse", date: lateYesterday), to: "projects/a/d.jsonl")
        let result = try await history([HistoryRoot(account: "claude", directory: home.url)])
        #expect(tokens(result) == 42)
        #expect(tokens(result, "claude", .yesterday) == 44)
    }

    @Test func cacheWritesUseTheSplitWhenItIsPresent() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let lines = [
            try assistant(
                "split", read: nil, write: 100,
                split: ["ephemeral_5m_input_tokens": 4, "ephemeral_1h_input_tokens": 6]),
            try assistant(
                "null-split", read: nil, write: 100,
                split: ["ephemeral_5m_input_tokens": NSNull()]),
            try assistant("other-split", read: nil, write: 100, split: ["other": 1]),
            try assistant("no-cache", read: nil, write: nil),
        ]
        try home.write(lines.joined(), to: "projects/a/one.jsonl")
        let result = try await history([HistoryRoot(account: "claude", directory: home.url)])
        let expected: Int64 = (13 + 10) + 13 + (13 + 100) + 13
        #expect(tokens(result) == expected)
        #expect(!result.history(for: "claude").isPartial)
    }

    @Test func linesThatCannotBeCountedMakeHistoryPartial() async throws {
        let lines: [(String, Int64)] = [
            ("{broken}\n", 0),
            (try assistant("no-input", input: NSNull()), 0),
            (try assistant("boolean", output: true), 0),
            (try assistant("fraction", input: 1.5), 0),
            (try assistant("negative", read: -1), 0),
            (try assistant("bad-date", date: "yesterday"), 0),
            (try assistant("future", date: Date.reference(.hours(1)).ISO8601Format()), 0),
            (try assistant(nil), 22),
        ]
        for (line, expected) in lines {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            try home.write(line + (try assistant("good", input: 0)), to: "projects/a/one.jsonl")
            let result = try await history([HistoryRoot(account: "claude", directory: home.url)])
            #expect(tokens(result) == 12 + expected, "\(line)")
            #expect(result.history(for: "claude").isPartial, "\(line)")
        }
    }

    @Test func otherLinesAreIgnoredWithoutMakingHistoryPartial() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let lines = [
            try assistant("user", type: "user"),
            #"{"type":"assistant","message":{"id":"m","content":"no usage"}}"# + "\n",
            #"{"type":"summary","summary":"text"}"# + "\n",
            try assistant("text-counts", input: "15", output: "5", read: "0", write: "0"),
            try assistant(
                "milliseconds", date: Int64(Date.reference().timeIntervalSince1970 * 1000)),
        ]
        try home.write(lines.joined(), to: "projects/a/one.jsonl")
        let result = try await history([HistoryRoot(account: "claude", directory: home.url)])
        #expect(tokens(result) == Int64(20 + 22))
        #expect(!result.history(for: "claude").isPartial)
    }

    @Test func eachAccountCountsOnlyItsOwnConfigDir() async throws {
        let personal = try TemporaryDirectory()
        let work = try TemporaryDirectory()
        let empty = try TemporaryDirectory()
        defer {
            personal.remove()
            work.remove()
            empty.remove()
        }
        try personal.write(try assistant("personal", input: 1_000), to: "projects/a/one.jsonl")
        try personal.write(try assistant("outside", input: 5_000), to: "todos/one.jsonl")
        try work.write(try assistant("work", input: 100), to: "projects/b/two.jsonl")
        let result = try await history([
            HistoryRoot(account: "claude", directory: personal.url),
            HistoryRoot(account: "claude-work", directory: work.url),
            HistoryRoot(account: "claude-empty", directory: empty.url),
        ])
        #expect(tokens(result) == 1_012)
        #expect(tokens(result, "claude-work") == 112)
        #expect(tokens(result, "claude-empty") == nil)
        #expect(!result.history(for: "claude-empty").hasRecords)
        #expect(tokens(result, "unmapped") == nil)
    }

    @Test func recordsGoToTheLocalDayOfTheCalendar() async throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        // 02:00 UTC: the evening before in Los Angeles, the same morning in Tokyo.
        try home.write(
            try assistant("early", date: Date.reference(-.hours(10)).ISO8601Format()),
            to: "projects/a/one.jsonl")
        let roots = [HistoryRoot(account: "claude", directory: home.url)]
        for (zone, period) in [
            ("America/Los_Angeles", TokenPeriod.yesterday), ("Asia/Tokyo", .today),
        ] {
            let zoned = Calendar.fixed(zone)
            let result = try await history(roots, calendar: zoned)
            #expect(result.timeZoneID == zone)
            #expect(tokens(result, "claude", period, calendar: zoned) == 22)
        }
    }
}

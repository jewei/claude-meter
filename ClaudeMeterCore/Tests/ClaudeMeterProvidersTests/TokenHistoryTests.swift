import ClaudeMeterCore
import Foundation
import Testing

@testable import ClaudeMeterProviders

private let tokenNow = Date(timeIntervalSince1970: 1_790_856_000)
private var tokenCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func jsonLine(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(10)
    return data
}

private func claudeLine(_ id: String, count: Int64, date: Date = tokenNow, padding: String = "")
    throws -> Data
{
    try jsonLine([
        "type": "assistant", "timestamp": date.ISO8601Format(), "requestId": "r-\(id)",
        "message": [
            "id": id, "model": "unknown-test-model", "content": padding,
            "usage": [
                "input_tokens": count, "output_tokens": 3,
                "cache_read_input_tokens": 7, "cache_creation_input_tokens": 2,
            ],
        ],
    ])
}

private final class TokenHistoryFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func append(_ data: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
    }
}

struct TokenHistoryTests {
    @Test func claudeStreamingCopiesAndUnknownModelsKeepCorrectTokens() async throws {
        let fixture = try TokenHistoryFixture()
        let yesterday = tokenNow.addingTimeInterval(-86400)
        let stream =
            try claudeLine("first", count: 10) + claudeLine("first", count: 20)
            + claudeLine("old", count: 30, date: yesterday)
        _ = try fixture.write("session.jsonl", stream)
        _ = try fixture.write("copied.jsonl", claudeLine("first", count: 10))
        let scanner = TokenHistoryScanner(provider: .claude)
        let result = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 32)
        #expect(result.tokens(for: .yesterday, asOf: tokenNow, calendar: tokenCalendar) == 42)
        #expect(result.tokens(for: .lastSevenDays, asOf: tokenNow, calendar: tokenCalendar) == 74)
        #expect(!result.isPartial)
    }

    @Test func warmScanSkipsBodiesAndAppendWaitsForCompleteLine() async throws {
        let fixture = try TokenHistoryFixture()
        let initial = try claudeLine(
            "first", count: 10, padding: String(repeating: "x", count: 100_000))
        let url = try fixture.write("session.jsonl", initial)
        let scanner = TokenHistoryScanner(provider: .claude)
        _ = try await scanner.scan(roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        _ = try await scanner.scan(roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        let unchanged = await scanner.work()
        #expect(unchanged.bytesRead == 0)
        #expect(unchanged.parsedLines == 0)
        #expect(unchanged.cacheHits == 1)
        let next = try claudeLine("second", count: 20)
        try fixture.append(next.dropLast(), to: url)
        let incomplete = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(incomplete.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 22)
        #expect(incomplete.isPartial)
        try fixture.append(Data([10]), to: url)
        let completed = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(completed.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 54)
        #expect(!completed.isPartial)
        let appended = await scanner.work()
        #expect(appended.parsedLines == 1)
        #expect(appended.bytesRead < 2048)
    }

    @Test func replacementTruncationAndDeletionRemoveOldCounts() async throws {
        let fixture = try TokenHistoryFixture()
        let url = try fixture.write("session.jsonl", claudeLine("first", count: 10))
        let scanner = TokenHistoryScanner(provider: .claude)
        _ = try await scanner.scan(roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        try claudeLine("new", count: 500).write(to: url, options: .atomic)
        let replaced = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(replaced.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 512)
        try Data().write(to: url)
        let empty = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(!empty.hasRecords)
        try FileManager.default.removeItem(at: url)
        let removed = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(removed.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == nil)
    }

    @Test func boundedScanResumesWithoutCountingThePrefixTwice() async throws {
        let fixture = try TokenHistoryFixture()
        var bytes = Data()
        for index in 0..<20 { bytes += try claudeLine("\(index)", count: 1) }
        _ = try fixture.write("session.jsonl", bytes)
        let scanner = TokenHistoryScanner(
            provider: .claude, limits: .init(scanBytes: 1500, fileBytes: 1000))
        var result = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(result.isPartial)
        for _ in 0..<30 where result.isPartial {
            let previous = result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) ?? 0
            result = try await scanner.scan(
                roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
            #expect(
                (result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) ?? 0)
                    > previous)
            #expect(await scanner.work().bytesRead <= 1500)
        }
        #expect(!result.isPartial)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 260)
    }

    @Test func directoryBudgetResumesAndKeepsEarlierFilesAcrossPages() async throws {
        let fixture = try TokenHistoryFixture()
        for index in 0..<7 {
            _ = try fixture.write("\(index).jsonl", claudeLine("\(index)", count: 10))
        }
        let scanner = TokenHistoryScanner(provider: .claude, limits: .init(directoryEntries: 2))
        var result = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(result.isPartial)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 44)
        for _ in 0..<8 where result.isPartial {
            let previous = result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) ?? 0
            result = try await scanner.scan(
                roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
            #expect(
                (result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) ?? 0)
                    >= previous)
            #expect(await scanner.work().directoryEntries <= 2)
        }
        #expect(!result.isPartial)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 154)
        // A new, incomplete sweep must not discard files beyond its first page.
        let next = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(next.isPartial)
        #expect(next.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 154)
        #expect(await scanner.work().bytesRead == 0)
    }

    @Test func discoveryEventuallyReachesRecentFileAfterOldEntries() async throws {
        let fixture = try TokenHistoryFixture()
        for index in 0..<7 {
            let url = try fixture.write("\(index).jsonl", claudeLine("\(index)", count: 10))
            try FileManager.default.setAttributes(
                [.modificationDate: tokenNow.addingTimeInterval(-30 * 86400)],
                ofItemAtPath: url.path)
        }
        // Assign the recent file after observing this fixture's directory order;
        // creating or renaming entries could change that order on different filesystems.
        let entries = try #require(
            FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil))
        let last = try #require((entries.allObjects as? [URL])?.last)
        try FileManager.default.setAttributes(
            [.modificationDate: tokenNow], ofItemAtPath: last.path)
        let scanner = TokenHistoryScanner(provider: .claude, limits: .init(directoryEntries: 2))
        var result = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        for _ in 0..<8 where result.isPartial {
            result = try await scanner.scan(
                roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
            #expect(await scanner.work().directoryEntries <= 2)
        }
        #expect(!result.isPartial)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 22)
    }

    @Test func discoverySharesItsBudgetAcrossRoots() async throws {
        let first = try TokenHistoryFixture()
        let second = try TokenHistoryFixture()
        for index in 0..<7 {
            _ = try first.write("\(index).jsonl", claudeLine("first-\(index)", count: 10))
        }
        _ = try second.write("only.jsonl", claudeLine("second", count: 100))
        let scanner = TokenHistoryScanner(provider: .claude, limits: .init(directoryEntries: 2))
        let result = try await scanner.scan(
            roots: [first.root, second.root], now: tokenNow, calendar: tokenCalendar)
        #expect(result.isPartial)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 134)
        #expect(await scanner.work().directoryEntries == 2)
        // A configuration change discards cursors and cached values from the old roots.
        let changed = try await scanner.scan(
            roots: [second.root], now: tokenNow, calendar: tokenCalendar)
        #expect(!changed.isPartial)
        #expect(changed.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 112)
    }

    @Test func completedSweepsFindInsertionsAndRemoveDeletedFiles() async throws {
        let fixture = try TokenHistoryFixture()
        let removed = try fixture.write("old.jsonl", claudeLine("old", count: 100))
        let kept = try fixture.write("kept.jsonl", claudeLine("kept", count: 10))
        let scanner = TokenHistoryScanner(provider: .claude, limits: .init(directoryEntries: 1))
        for _ in 0..<3 {
            _ = try await scanner.scan(
                roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        }
        // Change the directory while the next sweep is in progress.
        _ = try await scanner.scan(roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        try FileManager.default.removeItem(at: removed)
        _ = try fixture.write("new.jsonl", claudeLine("new", count: 20))
        try fixture.append(claudeLine("appended", count: 30), to: kept)
        var result = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        // Allow both the interrupted sweep and a fresh sweep to finish.
        for _ in 0..<8 {
            result = try await scanner.scan(
                roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
            #expect(await scanner.work().directoryEntries <= 1)
        }
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 96)
    }

    @Test func replacingARootAtTheSamePathInvalidatesItsCursor() async throws {
        let fixture = try TokenHistoryFixture()
        _ = try fixture.write("logs/one.jsonl", claudeLine("old-one", count: 100))
        _ = try fixture.write("logs/two.jsonl", claudeLine("old-two", count: 100))
        let root = fixture.root.appendingPathComponent("logs")
        let scanner = TokenHistoryScanner(provider: .claude, limits: .init(directoryEntries: 1))
        _ = try await scanner.scan(roots: [root], now: tokenNow, calendar: tokenCalendar)
        try FileManager.default.moveItem(
            at: root, to: fixture.root.appendingPathComponent("previous-logs"))
        _ = try fixture.write("logs/new.jsonl", claudeLine("new", count: 10))
        _ = try await scanner.scan(roots: [root], now: tokenNow, calendar: tokenCalendar)
        let result = try await scanner.scan(roots: [root], now: tokenNow, calendar: tokenCalendar)
        #expect(!result.isPartial)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 22)
    }

    @Test func fileAndRecordCapsRemainBoundedAcrossDiscoveryPages() async throws {
        let fixture = try TokenHistoryFixture()
        for index in 0..<7 {
            let url = try fixture.write(
                "\(index).jsonl", claudeLine("\(index)", count: Int64(index)))
            try FileManager.default.setAttributes(
                [.modificationDate: tokenNow.addingTimeInterval(Double(-index))],
                ofItemAtPath: url.path)
        }
        let scanner = TokenHistoryScanner(
            provider: .claude, limits: .init(files: 2, records: 1, directoryEntries: 3))
        var result = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        for _ in 0..<10 {
            result = try await scanner.scan(
                roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
            let work = await scanner.work()
            #expect(work.directoryEntries <= 3)
            #expect(work.discoveredFiles <= 2)
            #expect(work.cachedFiles <= 2)
            #expect(work.cachedRecords <= 1)
        }
        #expect(result.isPartial)
        // The most recently modified file gets the available record budget.
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 12)
    }

    @Test func cancellationBetweenPagesKeepsDiscoveryProgress() async throws {
        let fixture = try TokenHistoryFixture()
        for index in 0..<5 {
            _ = try fixture.write("\(index).jsonl", claudeLine("\(index)", count: 10))
        }
        let scanner = TokenHistoryScanner(provider: .claude, limits: .init(directoryEntries: 1))
        _ = try await scanner.scan(roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner.scan(
                roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        var result = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        for _ in 0..<6 where result.isPartial {
            result = try await scanner.scan(
                roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        }
        #expect(!result.isPartial)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 110)
    }

    @Test func grokUsesCompletedTurnsAndEventDatesWithoutReasoningDoubleCount() async throws {
        let fixture = try TokenHistoryFixture()
        func turn(_ id: String, _ date: Date) throws -> Data {
            try jsonLine([
                "params": [
                    "_meta": [
                        "eventId": id, "agentTimestampMs": date.timeIntervalSince1970 * 1000,
                    ],
                    "update": [
                        "sessionUpdate": "turn_completed",
                        "usage": [
                            "modelUsage": [
                                "unknown-model": [
                                    "inputTokens": 1000, "outputTokens": 50,
                                    "cachedReadTokens": 700, "cacheCreationTokens": 100,
                                    "reasoningTokens": 20,
                                ]
                            ]
                        ],
                    ],
                ]
            ])
        }
        let yesterday = tokenNow.addingTimeInterval(-86400)
        _ = try fixture.write("one/updates.jsonl", turn("one", tokenNow) + turn("two", yesterday))
        _ = try fixture.write("child/updates.jsonl", turn("one", tokenNow))
        let scanner = TokenHistoryScanner(provider: .grok)
        let result = try await scanner.scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 1050)
        #expect(result.tokens(for: .yesterday, asOf: tokenNow, calendar: tokenCalendar) == 1050)
        #expect(!result.isPartial)
    }

    @Test func malformedCountsAndFutureDatesStayPartial() async throws {
        let fixture = try TokenHistoryFixture()
        var bytes = try claudeLine("okay", count: 5)
        bytes += Data("{broken}\n".utf8)
        bytes += try claudeLine("future", count: 50, date: tokenNow.addingTimeInterval(86400))
        _ = try fixture.write("session.jsonl", bytes)
        let result = try await TokenHistoryScanner(provider: .claude).scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(result.isPartial)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 17)
        #expect(TokenJSON.count(true) == nil)
        #expect(TokenJSON.count(-1) == nil)
        #expect(TokenJSON.sum([Int64.max, 1]) == nil)
    }
}

struct CodexTokenHistoryTests {
    private func metadata(_ id: String, parent: String? = nil, ordinal: Int? = nil) -> [String: Any]
    {
        var payload: [String: Any] = [
            "id": id, "timestamp": tokenNow.addingTimeInterval(-5).ISO8601Format(),
        ]
        if let parent { payload["forked_from_id"] = parent }
        if let ordinal { payload["subagent_history_start_ordinal"] = ordinal }
        return ["type": "session_meta", "payload": payload]
    }

    private func event(
        input: Int, output: Int, lastInput: Int, lastOutput: Int, date: Date = tokenNow,
        ordinal: Int = 0, id: String = "response"
    ) -> [String: Any] {
        [
            "type": "event_msg", "timestamp": date.ISO8601Format(), "ordinal": ordinal,
            "payload": [
                "type": "token_count",
                "info": [
                    "response_id": id,
                    "total_token_usage": [
                        "input_tokens": input, "output_tokens": output,
                        "cached_input_tokens": input / 2, "reasoning_output_tokens": output / 2,
                    ],
                    "last_token_usage": ["input_tokens": lastInput, "output_tokens": lastOutput],
                ],
            ],
        ]
    }

    @Test func cumulativeSnapshotsAndArchivesAreCountedOnceAcrossMidnight() async throws {
        let fixture = try TokenHistoryFixture()
        let first = event(
            input: 100, output: 10, lastInput: 100, lastOutput: 10,
            date: tokenNow.addingTimeInterval(-86400), id: "one")
        let second = event(input: 160, output: 16, lastInput: 60, lastOutput: 6, id: "two")
        let bytes =
            try jsonLine(metadata("session")) + jsonLine(first) + jsonLine(second)
            + jsonLine(second)
        _ = try fixture.write("sessions/active.jsonl", bytes)
        _ = try fixture.write("archived/copy.jsonl", bytes)
        let result = try await TokenHistoryScanner(provider: .codex).scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 66)
        #expect(result.tokens(for: .yesterday, asOf: tokenNow, calendar: tokenCalendar) == 110)
        #expect(!result.isPartial)
    }

    @Test func inheritedForkPrefixUsesItsOwnedOrdinal() async throws {
        let fixture = try TokenHistoryFixture()
        let inherited = event(
            input: 100, output: 10, lastInput: 100, lastOutput: 10, ordinal: 10, id: "parent")
        let owned = event(
            input: 150, output: 15, lastInput: 50, lastOutput: 5, ordinal: 50, id: "child")
        _ = try fixture.write("parent.jsonl", jsonLine(metadata("parent")) + jsonLine(inherited))
        _ = try fixture.write(
            "child.jsonl",
            jsonLine(metadata("child", parent: "parent", ordinal: 50))
                + jsonLine(inherited) + jsonLine(owned))
        let result = try await TokenHistoryScanner(provider: .codex).scan(
            roots: [fixture.root], now: tokenNow, calendar: tokenCalendar)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 165)
        #expect(!result.isPartial)
    }

    @Test func unresolvedForkDoesNotClaimInheritedTokens() {
        var log = CodexTokenLog()
        log.append(metadata("child", parent: "missing"))
        log.append(event(input: 1000, output: 100, lastInput: 10, lastOutput: 1))
        let result = log.reconciled(parent: nil)
        #expect(result.events.isEmpty)
        #expect(result.partial)
    }

    @Test func repeatedCountersWithoutResponseIDsDoNotMakeHistoryPartial() {
        var log = CodexTokenLog()
        log.append(metadata("session"))
        var repeated = event(input: 100, output: 10, lastInput: 100, lastOutput: 10)
        var payload = repeated["payload"] as! [String: Any]
        var info = payload["info"] as! [String: Any]
        info.removeValue(forKey: "response_id")
        payload["info"] = info
        repeated["payload"] = payload
        log.append(repeated)
        log.append(repeated)
        let result = log.reconciled(parent: nil)
        #expect(result.events.reduce(0) { $0 + $1.count } == 110)
        #expect(!result.partial)
    }
}

struct CursorTokenHistoryTests {
    private let header =
        "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost\r\n"

    @Test func csvCountsUnknownModelsAndQuotedFieldsWithoutPrices() throws {
        let csv = header + "\(tokenNow.ISO8601Format()),\"unknown, model\",2,10,\"1,000\",3,-\r\n"
        let result = try CursorTokenCSV.parse(
            Data(csv.utf8), now: tokenNow, calendar: tokenCalendar)
        #expect(result.tokens(for: .today, asOf: tokenNow, calendar: tokenCalendar) == 1015)
        #expect(!result.isPartial)
    }

    @Test func emptyExportIsZeroButMalformedSchemaFails() throws {
        let result = try CursorTokenCSV.parse(
            Data(header.utf8), now: tokenNow, calendar: tokenCalendar)
        #expect(result.tokens(for: .lastSevenDays, asOf: tokenNow, calendar: tokenCalendar) == 0)
        #expect(throws: TokenHistoryError.self) {
            try CursorTokenCSV.parse(
                Data("Date,Cost\n".utf8), now: tokenNow, calendar: tokenCalendar)
        }
        #expect(throws: TokenHistoryError.self) {
            try CursorTokenCSV.parse(
                Data((header + "\"unterminated").utf8), now: tokenNow, calendar: tokenCalendar)
        }
    }

    @Test func badRowsMakeCoveragePartialAndSevenDaysExcludeEighthDate() throws {
        let old = tokenNow.addingTimeInterval(-7 * 86400)
        let csv =
            header + "\(old.ISO8601Format()),model,0,10000,0,0,-\n"
            + "\(tokenNow.ISO8601Format()),model,0,10,0,3,-\n"
            + "\(tokenNow.ISO8601Format()),model,0,-10,0,0,-\n"
        let result = try CursorTokenCSV.parse(
            Data(csv.utf8), now: tokenNow, calendar: tokenCalendar)
        #expect(result.isPartial)
        #expect(result.tokens(for: .lastSevenDays, asOf: tokenNow, calendar: tokenCalendar) == 13)
    }

    @Test func requestUsesSevenDaysAndExistingTokenOnly() throws {
        let payload = Data(#"{"sub":"auth0|test_user"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let token = "header.\(payload).signature"
        let request = try CursorTokenUsageSource.request(
            token: token, now: tokenNow, calendar: tokenCalendar)
        #expect(request.url?.host == "cursor.com")
        #expect(
            request.value(forHTTPHeaderField: "Cookie")
                == "WorkosCursorSessionToken=test_user%3A%3A\(token)")
        let query = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        let start = try #require(
            TokenUsagePeriod.lastSevenDays.interval(asOf: tokenNow, calendar: tokenCalendar)
        ).start
        #expect(
            query.first(where: { $0.name == "startDate" })?.value
                == String(Int64(start.timeIntervalSince1970 * 1000)))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

private final class TokenCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CursorCredentials?

    init() { value = Self.make("first") }
    func load() -> CursorCredentials? { lock.withLock { value } }
    func change() { lock.withLock { value = Self.make("second") } }

    private static func make(_ id: String) -> CursorCredentials {
        let payload = Data("{\"sub\":\"auth0|\(id)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return CursorCredentials(
            accessToken: "header.\(payload).signature", refreshToken: nil, email: nil,
            membership: nil)
    }
}

private struct TokenExportTransport: HTTPTransport {
    let beforeResponse: @Sendable () -> Void
    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (Data, HTTPURLResponse)
    {
        beforeResponse()
        return (
            Data(
                "Date,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens\n"
                    .utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
struct TokenHistoryOwnershipTests {
    @Test func accountChangeClearsThePreviousExport() async throws {
        let credentials = TokenCredentials()
        let source = CursorTokenUsageSource(
            transport: TokenExportTransport(beforeResponse: {}), credentials: { credentials.load() }
        )
        let firstID = UUID()
        _ = try await source.validatePrevious(nil, refreshID: firstID)
        let first = try await source.fetch(now: tokenNow, refreshID: firstID)
        source.didAccept(first, refreshID: firstID)
        let same = try await source.validatePrevious(first, refreshID: UUID())
        #expect(same == first)
        credentials.change()
        let changed = try await source.validatePrevious(first, refreshID: UUID())
        #expect(changed == nil)
    }

    @Test func accountChangeDuringRequestRejectsTheResponse() async throws {
        let credentials = TokenCredentials()
        let source = CursorTokenUsageSource(
            transport: TokenExportTransport(beforeResponse: { credentials.change() }),
            credentials: { credentials.load() })
        let id = UUID()
        _ = try await source.validatePrevious(nil, refreshID: id)
        do {
            _ = try await source.fetch(now: tokenNow, refreshID: id)
            Issue.record("A response from the old login was accepted")
        } catch let failure as UsageProviderFailure {
            #expect(!failure.retainsLastGood)
        }
    }
}

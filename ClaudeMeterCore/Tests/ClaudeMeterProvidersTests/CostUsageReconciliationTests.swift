import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Cost request reconciliation", .serialized)
struct CostUsageReconciliationTests {
    private func withRoot(_ body: (URL, Date) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, Date())
    }

    private func line(
        id: String? = "shared", request: String? = "request", input: Int = 100, output: Int = 0,
        model: String = "claude-sonnet-4-6", now: Date,
        legacy: Int = 0, fiveMinute: Int? = nil, oneHour: Int? = nil
    ) throws -> String {
        var usage: [String: Any] = [
            "input_tokens": input, "output_tokens": output, "cache_creation_input_tokens": legacy,
        ]
        if fiveMinute != nil || oneHour != nil {
            usage["cache_creation"] = [
                "ephemeral_5m_input_tokens": fiveMinute ?? 0,
                "ephemeral_1h_input_tokens": oneHour ?? 0,
            ]
        }
        var message: [String: Any] = ["model": model, "usage": usage]
        if let id { message["id"] = id }
        var entry: [String: Any] = [
            "type": "assistant", "timestamp": ISO8601DateFormatter().string(from: now),
            "message": message,
        ]
        if let request { entry["requestId"] = request }
        return String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    }

    @discardableResult
    private func write(_ lines: [String], root: URL, path: String) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        return file
    }

    @Test func copiedHistoryKeepsBothContinuationsAcrossCacheAndRelaunch() throws {
        try withRoot { root, now in
            let shared = try line(now: now)
            try write(
                [shared, line(id: "original-next", input: 20, now: now)],
                root: root, path: "project/session-original.jsonl")
            try write(
                [shared, line(id: "fork-next", input: 30, now: now)],
                root: root, path: "project/session-fork.jsonl")
            let cacheURL = root.appendingPathComponent("cache.json")
            let cache = CostUsageCache(persistenceURL: cacheURL)
            let scanner = CostUsageScanner(projectsPath: root, cache: cache)
            for result in [
                scanner.scan(now: now), scanner.scan(now: now),
                CostUsageScanner(
                    projectsPath: root, cache: CostUsageCache(persistenceURL: cacheURL)
                )
                .scan(now: now),
            ] {
                #expect(result.models.first?.inputTokens == 150)
                #expect(!result.isPartialEstimate)
            }
        }
    }

    @Test func identitiesAreSharedWithinARootButNeverAcrossAccounts() throws {
        try withRoot { root, now in
            let accountA = root.appendingPathComponent("account-a")
            let accountB = root.appendingPathComponent("account-b")
            let shared = try line(now: now)
            try write([shared], root: accountA, path: "project-a/session.jsonl")
            try write([shared], root: accountA, path: "project-b/session.jsonl")
            try write(
                [shared, line(id: "worker", input: 30, now: now)], root: accountA,
                path: "project-a/session/subagents/agent-worker.jsonl")
            try write([shared], root: accountB, path: "project/session.jsonl")
            let result = CostUsageScanner(
                projectsPaths: [accountA, accountB], cache: CostUsageCache()
            )
            .scan(now: now)
            #expect(result.models.first?.inputTokens == 230)
            #expect(!result.isPartialEstimate)
        }
    }

    @Test(arguments: [false, true])
    func copiedChunksKeepMaximaAndExplicitCacheTiers(reverse: Bool) throws {
        try withRoot { root, now in
            let provisional = try line(input: 200, output: 5, now: now, legacy: 300)
            let detailed = try line(input: 100, output: 15, now: now, fiveMinute: 50, oneHour: 250)
            try write([reverse ? detailed : provisional], root: root, path: "p/a.jsonl")
            try write([reverse ? provisional : detailed], root: root, path: "p/b.jsonl")
            let cacheURL = root.appendingPathComponent("cache.json")
            for _ in 0..<2 {
                let result = CostUsageScanner(
                    projectsPath: root, cache: CostUsageCache(persistenceURL: cacheURL)
                ).scan(now: now)
                let usage = try #require(result.models.first)
                #expect(usage.inputTokens == 200)
                #expect(usage.outputTokens == 15)
                #expect(usage.cacheWriteTokens == 300)
                #expect(abs((usage.costUsd ?? 0) - 0.0025125) < 0.000_000_1)
            }
        }
    }

    @Test(arguments: [0, 1, 2])
    func incompleteIdentitiesRemainSeparateAcrossFiles(missing: Int) throws {
        try withRoot { root, now in
            let row = try line(
                id: missing == 0 ? "message" : nil,
                request: missing == 1 ? "request" : nil, now: now)
            try write([row], root: root, path: "p/a.jsonl")
            try write([row], root: root, path: "p/b.jsonl")
            let cacheURL = root.appendingPathComponent("cache.json")
            for _ in 0..<2 {
                let result = CostUsageScanner(
                    projectsPath: root, cache: CostUsageCache(persistenceURL: cacheURL)
                ).scan(now: now)
                #expect(result.models.first?.inputTokens == 200)
            }
        }
    }

    @Test func identityComponentsCannotCollideAtASeparator() throws {
        try withRoot { root, now in
            try write([line(id: "a|b", request: "c", now: now)], root: root, path: "p/a.jsonl")
            try write([line(id: "a", request: "b|c", now: now)], root: root, path: "p/b.jsonl")
            #expect(
                CostUsageScanner(projectsPath: root, cache: CostUsageCache())
                    .scan(now: now).models.first?.inputTokens == 200)
        }
    }

    @Test func deletionAndLargerReplacementRemoveOldContributions() throws {
        try withRoot { root, now in
            let first = try write([line(now: now)], root: root, path: "p/a.jsonl")
            let second = try write(
                [line(now: now), line(id: "next", input: 30, now: now)],
                root: root, path: "p/b.jsonl")
            let scanner = CostUsageScanner(projectsPath: root, cache: CostUsageCache())
            #expect(scanner.scan(now: now).models.first?.inputTokens == 130)
            try FileManager.default.removeItem(at: second)
            #expect(scanner.scan(now: now).models.first?.inputTokens == 100)
            let replacement = try line(id: "replacement-with-a-longer-id", input: 700, now: now)
            try Data(replacement.utf8).write(to: first)
            #expect(scanner.scan(now: now).models.first?.inputTokens == 700)
        }
    }

    @Test func aggregateOnlyVersionFourCacheIsDiscarded() throws {
        try withRoot { root, now in
            try write([line(now: now)], root: root, path: "p/a.jsonl")
            let url = root.appendingPathComponent("cache.json")
            try Data(#"{"version":4,"entries":[]}"#.utf8).write(to: url)
            let cache = CostUsageCache(persistenceURL: url)
            #expect(cache.entryCount == 0)
            #expect(
                CostUsageScanner(projectsPath: root, cache: cache)
                    .scan(now: now).models.first?.inputTokens == 100)
        }
    }

    @Test func cacheByteBudgetEvictsAndSurvivesReloadAndTrim() throws {
        try withRoot { root, now in
            let url = root.appendingPathComponent("cache.json")
            let cache = CostUsageCache(persistenceURL: url, maximumRetainedBytes: 1100)
            let record = CostUsageScanner.RequestRecord(
                identity: .init(messageID: "message", requestID: "request"),
                day: "2026-09-05", model: "test", totals: .zero, hasCacheWriteBreakdown: false)
            for index in 0..<5 {
                let file = try write([], root: root, path: "p/\(index).jsonl")
                cache.store(
                    file: file.path, modDate: now, fileSize: 0,
                    scan: .init(isPartial: false, records: [record]))
            }
            #expect(cache.entryCount > 0 && cache.entryCount < 5)
            #expect(cache.retainedByteCount <= 1100)
            cache.flush()
            let reloaded = CostUsageCache(persistenceURL: url, maximumRetainedBytes: 1100)
            #expect(reloaded.entryCount == cache.entryCount)
            #expect(reloaded.retainedByteCount == cache.retainedByteCount)
            reloaded.trimMemory()
            #expect(reloaded.retainedByteCount == 0)
            #expect(reloaded.entryCount == 0)
        }
    }

    @Test func fileAndRootRecordBoundsProduceRepeatablePartialResults() throws {
        try withRoot { root, now in
            let timestamp = ISO8601DateFormatter().string(from: now)
            func rows(start: Int, count: Int) -> [String] {
                (start..<(start + count)).map { index in
                    """
                    {"type":"assistant","timestamp":"\(timestamp)","requestId":"r",\
                    "message":{"id":"\(index)","model":"test","usage":{"input_tokens":1}}}
                    """
                }
            }
            let fileLimit = CostUsageScanner.maximumFileRecords
            try write(rows(start: 0, count: fileLimit + 1), root: root, path: "p/0.jsonl")
            let scanner = CostUsageScanner(projectsPath: root, cache: CostUsageCache())
            let first = scanner.scan(now: now)
            #expect(first.models.first?.inputTokens == fileLimit)
            #expect(first.isPartialEstimate)
            for index in 1...5 {
                try write(
                    rows(start: index * fileLimit, count: fileLimit),
                    root: root, path: "p/\(index).jsonl")
            }
            for result in [scanner.scan(now: now), scanner.scan(now: now)] {
                #expect(result.models.first?.inputTokens == CostUsageScanner.maximumRootRecords)
                #expect(result.isPartialEstimate)
            }
        }
    }
}

import ClaudeMeterCore
import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Cost transcript append parsing")
struct CostUsageAppendTests {
    private struct Fixture {
        let root: URL
        let file: URL
        let now = Date()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let project = root.appendingPathComponent("p")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            file = project.appendingPathComponent("session.jsonl")
        }

        func line(_ id: String?, input: Int, requestID: Bool = true) -> String {
            let messageID = id.map { "\"id\":\"\($0)\"," } ?? ""
            let request = requestID ? "\"requestId\":\"request\"," : ""
            return """
                {"type":"assistant","timestamp":"\(ISO8601DateFormatter().string(from: now))",\
                \(request)"message":{\(messageID)"model":"claude-sonnet-4-6",\
                "usage":{"input_tokens":\(input)}}}
                """
        }

        func write(_ text: String) throws { try Data(text.utf8).write(to: file) }

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        func scan(
            cache: CostUsageCache, work: CostUsageScanner.WorkRecorder? = nil
        ) -> CostUsageResult {
            CostUsageScanner(
                projectsPaths: [root], pricing: .current, cache: cache,
                calendar: .current, workRecorder: work
            ).scan(now: now)
        }
    }

    @Test("Successive appends verify the whole prefix but parse only new bytes")
    func appendedWorkIsBoundedBySuffix() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = CostUsageCache()
        let initial = (0..<100).map { fixture.line("m\($0)", input: 100) + "\n" }.joined()
        try fixture.write(initial)
        _ = fixture.scan(cache: cache)
        var size = initial.utf8.count
        for index in 100..<103 {
            let tail = fixture.line("m\(index)", input: 50) + "\n"
            try fixture.append(tail)
            let work = CostUsageScanner.WorkRecorder()
            let result = fixture.scan(cache: cache, work: work)
            #expect(result == fixture.scan(cache: CostUsageCache()))
            #expect(work.snapshot().fullParses == 0)
            #expect(work.snapshot().appendParses == 1)
            #expect(work.snapshot().parsedBytes == tail.utf8.count)
            #expect(work.snapshot().prefixBytesRead == UInt64(size))
            size += tail.utf8.count
        }
        let warm = CostUsageScanner.WorkRecorder()
        _ = fixture.scan(cache: cache, work: warm)
        #expect(warm.snapshot().cacheHits == 1)
        #expect(warm.snapshot().parsedBytes == 0)
        #expect(warm.snapshot().prefixBytesRead == 0)
    }

    @Test("A rewrite after 64 KiB cannot retain the old totals")
    func fullPrefixDetectsLateRewrite() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let padding =
            "{\"type\":\"user\",\"text\":\"" + String(repeating: "x", count: 70_000) + "\"}\n"
        let original = padding + fixture.line("old", input: 100) + "\n"
        try fixture.write(original)
        let cache = CostUsageCache()
        _ = fixture.scan(cache: cache)
        // FileHandle preserves the inode; the first 64 KiB also remain identical.
        let replacement =
            padding + fixture.line("old", input: 900) + "\n"
            + fixture.line("new", input: 10) + "\n"
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()
        let work = CostUsageScanner.WorkRecorder()
        let result = fixture.scan(cache: cache, work: work)
        #expect(result.models.first?.inputTokens == 910)
        #expect(result == fixture.scan(cache: CostUsageCache()))
        #expect(work.snapshot().fullParses == 1)
        #expect(work.snapshot().appendParses == 0)
    }

    @Test("Unterminated cumulative maxima can be revoked after cache reload")
    func provisionalRecordNeverEntersCommittedState() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let disk = fixture.root.appendingPathComponent("cache.json")
        try fixture.write(fixture.line("m", input: 100) + "\n" + fixture.line("m", input: 900))
        let cache = CostUsageCache(persistenceURL: disk)
        #expect(fixture.scan(cache: cache).models.first?.inputTokens == 900)
        cache.flush()
        let reloaded = CostUsageCache(persistenceURL: disk)
        // Appended bytes make the formerly valid EOF JSON invalid.
        try fixture.append("invalid\n")
        let work = CostUsageScanner.WorkRecorder()
        let result = fixture.scan(cache: reloaded, work: work)
        #expect(result.models.first?.inputTokens == 100)
        #expect(result == fixture.scan(cache: CostUsageCache()))
        #expect(work.snapshot().appendParses == 1)
        #expect(reloaded.retainedByteCount <= CostUsageCache.maximumRetainedBytes)
    }

    @Test("A partial UTF-8/JSON line is reread and counted only when it completes")
    func incompleteLineCanFinishAcrossReads() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prefix = fixture.line("first", input: 10) + "\n"
        let finalLine = Data((fixture.line("最後", input: 20) + "\n").utf8)
        let split = try #require(finalLine.firstIndex(of: 0xE6)) + 1
        try (Data(prefix.utf8) + finalLine.prefix(split)).write(to: fixture.file)
        let cache = CostUsageCache()
        #expect(fixture.scan(cache: cache).models.first?.inputTokens == 10)
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: finalLine.suffix(finalLine.count - split))
        try handle.close()
        let result = fixture.scan(cache: cache)
        #expect(result.models.first?.inputTokens == 30)
        #expect(result == fixture.scan(cache: CostUsageCache()))
    }

    @Test("File-local message IDs survive reload while anonymous records stay additive")
    func incompleteIdentityKeepsItsFileMergeRule() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let disk = fixture.root.appendingPathComponent("cache.json")
        try fixture.write(
            fixture.line("local", input: 100, requestID: false) + "\n"
                + fixture.line(nil, input: 10, requestID: false) + "\n")
        let cache = CostUsageCache(persistenceURL: disk)
        _ = fixture.scan(cache: cache)
        cache.flush()
        try fixture.append(
            fixture.line("local", input: 250, requestID: false) + "\n"
                + fixture.line(nil, input: 10, requestID: false) + "\n")
        let reloaded = CostUsageCache(persistenceURL: disk)
        let work = CostUsageScanner.WorkRecorder()
        let result = fixture.scan(cache: reloaded, work: work)
        #expect(result.models.first?.inputTokens == 270)
        #expect(result == fixture.scan(cache: CostUsageCache()))
        #expect(work.snapshot().appendParses == 1)
    }

    @Test("Cache-write tier provenance survives cumulative appends")
    func cacheWriteProvenanceSurvivesAppend() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacy = fixture.line("m", input: 100).replacingOccurrences(
            of: "\"input_tokens\":100",
            with: "\"input_tokens\":100,\"cache_creation_input_tokens\":1000")
        try fixture.write(legacy + "\n")
        let cache = CostUsageCache()
        _ = fixture.scan(cache: cache)
        let detailed = fixture.line("m", input: 100).replacingOccurrences(
            of: "\"input_tokens\":100",
            with:
                "\"input_tokens\":100,\"cache_creation\":{\"ephemeral_5m_input_tokens\":20,\"ephemeral_1h_input_tokens\":80}"
        )
        try fixture.append(detailed + "\n" + legacy + "\n")
        let result = fixture.scan(cache: cache)
        #expect(result.models.first?.cacheWriteTokens == 100)
        #expect(result == fixture.scan(cache: CostUsageCache()))
    }

    @Test("Crossing the full-read limit discards the cursor and keeps tail bounds")
    func currentSizeControlsReadLimit() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write(String(repeating: "a", count: 23) + "\n")
        let first = try #require(
            JournalReader.readRegularTranscript(
                at: fixture.file, maxFullReadBytes: 32, tailReadBytes: 16, trackAppend: true))
        let cursor = try #require(first.appendCursor)
        try fixture.append(String(repeating: "b", count: 11) + "\n")
        let next = try #require(
            JournalReader.readRegularTranscript(
                at: fixture.file, maxFullReadBytes: 32, tailReadBytes: 16,
                trackAppend: true, appendCursor: cursor))
        #expect(!next.isAppend)
        #expect(next.isPartial)
        #expect(next.data.count == 16)
        #expect(next.appendCursor == nil)
    }

    @Test("A mutation during append reading cannot admit the next cursor")
    func racedAppendIsNotCached() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write("first\n")
        let first = try #require(
            JournalReader.readRegularTranscript(
                at: fixture.file, maxFullReadBytes: 100, tailReadBytes: 16, trackAppend: true))
        try fixture.append("second\n")
        let next = try #require(
            JournalReader.readRegularTranscript(
                at: fixture.file, maxFullReadBytes: 100, tailReadBytes: 16,
                trackAppend: true, appendCursor: first.appendCursor,
                afterRead: { try! fixture.append("third\n") }))
        #expect(next.isAppend)
        #expect(next.isPartial)
        #expect(!next.isCacheable)
        #expect(next.appendCursor == nil)
    }
}

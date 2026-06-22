import Testing
import Foundation
@testable import ClaudeMeterCore

private let fixedNow = Date(timeIntervalSince1970: 1_782_108_000)
private let klTZ = TimeZone(identifier: "Asia/Kuala_Lumpur")!

private func makeStore() throws -> SnapshotStore {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "ClaudeMeterPipeline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return SnapshotStore(directory: dir)
}

private func makeParser() -> ClaudeOutputParser {
    ClaudeOutputParser(
        cliPath: "/opt/homebrew/bin/claude",
        command: "claude status",
        timeZone: klTZ
    )
}

private func fixture(_ name: String) throws -> String {
    let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")
    let path = url ?? URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).txt")
    return try String(contentsOf: path, encoding: .utf8)
}

@Suite("SnapshotPipeline")
struct SnapshotPipelineTests {

    @Test("Poll parses status output and persists snapshot")
    func pollSuccess() async throws {
        let store = try makeStore()
        let statusText = try fixture("minimal")
        let runner = MockCommandRunner(statusOutput: statusText)
        let pipeline = SnapshotPipeline(runner: runner, parser: makeParser(), store: store)

        let result = try await pipeline.poll(now: fixedNow)

        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)
        #expect(snap.limits.currentSession.percentUsed == 25)
        #expect(snap.lastSuccessfulPollAt == fixedNow)

        let stored = try #require(try store.readLatest())
        #expect(stored == snap)
        #expect(try store.readLastError() == nil)
    }

    @Test("Poll merges stats output into parse input")
    func pollMergesStats() async throws {
        let store = try makeStore()
        let statusText = try fixture("minimal")
        let statsText = try fixture("stats_table")
        let runner = MockCommandRunner(statusOutput: statusText, statsOutput: statsText)
        let pipeline = SnapshotPipeline(runner: runner, parser: makeParser(), store: store)

        let result = try await pipeline.poll(now: fixedNow)
        let snap = try #require(result.snapshot)

        #expect(snap.session?.totalCostUsd == 21.20)
        #expect(snap.models.count == 2)
    }

    @Test("Poll records last error on parse failure")
    func pollParseFailure() async throws {
        let store = try makeStore()
        let runner = MockCommandRunner(statusOutput: "Version: 2.1.185\n")
        let pipeline = SnapshotPipeline(runner: runner, parser: makeParser(), store: store)

        let result = try await pipeline.poll(now: fixedNow)

        #expect(result.isFatal)
        let error = try #require(try store.readLastError())
        #expect(error.message.contains("No usage-limit blocks"))
        #expect(try store.readLatest() == nil)
    }

    @Test("Poll records last error on command failure")
    func pollCommandFailure() async throws {
        let store = try makeStore()
        let runner = MockCommandRunner(statusError: CommandError.timeout(seconds: 5))
        let pipeline = SnapshotPipeline(runner: runner, parser: makeParser(), store: store)

        await #expect(throws: CommandError.timeout(seconds: 5)) {
            try await pipeline.poll(now: fixedNow)
        }

        let error = try #require(try store.readLastError())
        #expect(error.message.contains("timeout"))
    }

    @Test("Poll continues when stats command fails")
    func pollIgnoresStatsFailure() async throws {
        let store = try makeStore()
        let statusText = try fixture("minimal")
        let runner = MockCommandRunner(
            statusOutput: statusText,
            statsError: CommandError.timeout(seconds: 5)
        )
        let pipeline = SnapshotPipeline(runner: runner, parser: makeParser(), store: store)

        let result = try await pipeline.poll(now: fixedNow)

        #expect(result.errors.isEmpty)
        #expect(result.snapshot?.limits.currentSession.percentUsed == 25)
    }

    @Test("Poll writes raw output when enabled")
    func pollRecordsRawOutput() async throws {
        let store = try makeStore()
        let statusText = try fixture("minimal")
        let runner = MockCommandRunner(statusOutput: statusText)
        let pipeline = SnapshotPipeline(
            runner: runner,
            parser: makeParser(),
            store: store,
            recordRawOutput: true
        )

        _ = try await pipeline.poll(now: fixedNow)

        let rawURL = store.directory.appendingPathComponent("current.raw.txt")
        let raw = try String(contentsOf: rawURL, encoding: .utf8)
        #expect(raw == statusText)
    }
}

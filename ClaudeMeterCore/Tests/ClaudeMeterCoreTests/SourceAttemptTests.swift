import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("Source attempt trail")
struct SourceAttemptTests {
    @Test func prependingKeepsFallbackOrder() {
        let result = ParseResult(
            snapshot: nil,
            warnings: [],
            errors: [],
            rawHash: "",
            sourceAttempts: [
                SourceAttempt(source: .cache, outcome: .selected, reason: .cachedSnapshot)
            ]
        )
        let combined = result.prependingSourceAttempt(
            SourceAttempt(source: .oauth, outcome: .skipped, reason: .sourceDisabled))

        #expect(combined.sourceAttempts.map(\.source) == [.oauth, .cache])
    }

    @Test func missingCacheReturnsATypedFatalAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = CachedSnapshotPipeline(store: SnapshotStore(directory: directory))

        let result = try await pipeline.poll(now: Date())

        #expect(result.isFatal)
        #expect(
            result.sourceAttempts == [
                SourceAttempt(source: .cache, outcome: .failed, reason: .cacheMissing)
            ])
    }

    @Test func corruptCacheIsDistinguishedFromAMissingCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not-json".utf8).write(to: directory.appending(path: "current.json"))
        let pipeline = CachedSnapshotPipeline(store: SnapshotStore(directory: directory))

        let result = try await pipeline.poll(now: Date())

        #expect(result.isFatal)
        #expect(result.sourceAttempts.last?.reason == .cacheUnreadable)
    }

    @Test func errorsAlongsideAUsableSnapshotAreDegradedNotFatal() {
        let snapshot = ClaudeUsageSnapshot(
            parserVersion: "test",
            createdAt: Date(),
            source: SourceInfo(cliPath: "test", command: "test"),
            limits: LimitInfo(),
            state: SnapshotState(status: .ok, severity: .normal))
        let result = ParseResult(
            snapshot: snapshot, warnings: [], errors: [ParseError("degraded")], rawHash: "")

        #expect(result.hasUsableSnapshot)
        #expect(!result.isFatal)
    }
}

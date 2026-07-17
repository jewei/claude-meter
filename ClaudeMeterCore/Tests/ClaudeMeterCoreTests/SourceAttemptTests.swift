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
}

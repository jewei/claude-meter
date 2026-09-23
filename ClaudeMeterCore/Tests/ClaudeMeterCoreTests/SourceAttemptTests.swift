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
            sourceAttempts: [
                SourceAttempt(source: .cache, outcome: .selected, reason: .cachedSnapshot)
            ]
        )
        let combined = result.prependingSourceAttempt(
            SourceAttempt(source: .oauth, outcome: .skipped, reason: .notConnected))

        #expect(combined.sourceAttempts.map(\.source) == [.oauth, .cache])
    }

    @Test func errorsAlongsideAUsableSnapshotAreDegradedNotFatal() {
        let snapshot = ClaudeUsageSnapshot(
            parserVersion: "test",
            createdAt: Date(),
            source: SourceInfo(cliPath: "test", command: "test"),
            limits: LimitInfo(),
            state: SnapshotState(status: .ok, severity: .normal))
        let result = ParseResult(
            snapshot: snapshot, warnings: [], errors: [ParseError("degraded")])

        #expect(result.hasUsableSnapshot)
        #expect(!result.isFatal)
    }
}

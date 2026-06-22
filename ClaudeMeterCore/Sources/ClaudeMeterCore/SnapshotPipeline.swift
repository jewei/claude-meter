import Foundation

/// Orchestrates CLI fetch → parse → persist for a single poll cycle.
public struct SnapshotPipeline: Sendable {
    public let runner: any ClaudeCommandRunner
    public let parser: ClaudeOutputParser
    public let store: SnapshotStore
    public let recordRawOutput: Bool

    public init(
        runner: any ClaudeCommandRunner,
        parser: ClaudeOutputParser,
        store: SnapshotStore,
        recordRawOutput: Bool = false
    ) {
        self.runner = runner
        self.parser = parser
        self.store = store
        self.recordRawOutput = recordRawOutput
    }

    /// Fetches CLI output, parses it, persists the snapshot on success,
    /// and records the last error on command or parse failure.
    public func poll(now: Date = Date()) async throws -> ParseResult {
        let combined: String
        do {
            let status = try await runner.fetchStatus()
            if recordRawOutput {
                try store.writeRawOutput(status.stdout)
            }
            combined = try await mergeStats(into: status.stdout)
        } catch {
            try? store.writeLastError(LastErrorRecord(occurredAt: now, message: String(describing: error)))
            throw error
        }

        let result = parser.parse(combined)
        if result.isFatal {
            let message = result.errors.map(\.message).joined(separator: "; ")
            try? store.writeLastError(LastErrorRecord(occurredAt: now, message: message))
            return result
        }

        guard var snapshot = result.snapshot else { return result }

        snapshot.lastSuccessfulPollAt = now
        try store.writeLatest(snapshot)
        try store.clearLastError()

        return ParseResult(
            snapshot: snapshot,
            warnings: result.warnings,
            errors: result.errors,
            rawHash: result.rawHash,
            parserVersion: result.parserVersion
        )
    }

    private func mergeStats(into statusText: String) async throws -> String {
        guard let stats = try await runner.fetchStats() else { return statusText }
        guard !stats.stdout.isEmpty else { return statusText }
        return statusText + "\n\n" + stats.stdout
    }
}

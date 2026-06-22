import Foundation

/// Reads ~/.claude/projects JSONL files for real-time message counts,
/// supplemented by ~/.claude/stats-cache.json for days older than the journal window.
public struct StatsCachePipeline: Sendable {
    public let reader: StatsCacheReader
    public let journal: JournalReader
    public let store: SnapshotStore
    public let dailyMessageLimit: Int?
    public let weeklyMessageLimit: Int?
    public let thresholds: UsageThresholds

    public init(
        reader: StatsCacheReader = StatsCacheReader(),
        journal: JournalReader = JournalReader(),
        store: SnapshotStore,
        dailyMessageLimit: Int? = nil,
        weeklyMessageLimit: Int? = nil,
        thresholds: UsageThresholds = .default
    ) {
        self.reader = reader
        self.journal = journal
        self.store = store
        self.dailyMessageLimit = dailyMessageLimit
        self.weeklyMessageLimit = weeklyMessageLimit
        self.thresholds = thresholds
    }

    public func poll(now: Date = Date()) async throws -> ParseResult {
        try await poll(now: now, journalCounts: nil)
    }

    public func poll(now: Date = Date(), journalCounts: [String: Int]?) async throws -> ParseResult {
        do {
            let counts = journalCounts ?? journal.messageCounts(daysBack: 7, now: now)

            var snapshot = try reader.read(
                dailyMessageLimit: dailyMessageLimit,
                weeklyMessageLimit: weeklyMessageLimit,
                supplementalCounts: counts,
                now: now,
                thresholds: thresholds
            )
            snapshot.lastSuccessfulPollAt = now
            try store.writeLatest(snapshot)
            try store.clearLastError()
            return ParseResult(
                snapshot: snapshot,
                warnings: [],
                errors: [],
                rawHash: "",
                parserVersion: "stats-cache-1.0"
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? store.writeLastError(LastErrorRecord(occurredAt: now, message: message))
            throw error
        }
    }
}

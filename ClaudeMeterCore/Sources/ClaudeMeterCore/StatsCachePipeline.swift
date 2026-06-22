import Foundation

/// Reads ~/.claude/projects JSONL files for real-time message counts,
/// supplemented by ~/.claude/stats-cache.json for days older than the journal window.
public struct StatsCachePipeline: Sendable {
    public let reader: StatsCacheReader
    public let journal: JournalReader
    public let store: SnapshotStore
    public let dailyMessageLimit: Int?
    public let weeklyMessageLimit: Int?

    public init(
        reader: StatsCacheReader = StatsCacheReader(),
        journal: JournalReader = JournalReader(),
        store: SnapshotStore,
        dailyMessageLimit: Int? = nil,
        weeklyMessageLimit: Int? = nil
    ) {
        self.reader = reader
        self.journal = journal
        self.store = store
        self.dailyMessageLimit = dailyMessageLimit
        self.weeklyMessageLimit = weeklyMessageLimit
    }

    public func poll(now: Date = Date()) async throws -> ParseResult {
        do {
            // Journal (JSONL) gives real-time counts for recent days
            let journalCounts = journal.messageCounts(daysBack: 7, now: now)

            var snapshot = try reader.read(
                dailyMessageLimit: dailyMessageLimit,
                weeklyMessageLimit: weeklyMessageLimit,
                supplementalCounts: journalCounts,
                now: now
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
            try? store.writeLastError(LastErrorRecord(occurredAt: now, message: String(describing: error)))
            throw error
        }
    }
}

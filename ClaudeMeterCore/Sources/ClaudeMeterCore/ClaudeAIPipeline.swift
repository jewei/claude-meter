import Foundation

/// Pipeline that fetches utilization percentages from claude.ai/api/organizations/{orgId}/usage
/// and enriches them with real-time message counts from the JSONL journal.
///
/// Falls back to `StatsCachePipeline` if the API call fails.
public struct ClaudeAIPipeline: ClaudeMeterPipeline {

    public let client: ClaudeAIUsageClient
    public let journal: JournalReader
    public let store: SnapshotStore
    public let fallback: StatsCachePipeline

    public init(
        client: ClaudeAIUsageClient,
        journal: JournalReader = JournalReader(),
        store: SnapshotStore,
        fallback: StatsCachePipeline
    ) {
        self.client = client
        self.journal = journal
        self.store = store
        self.fallback = fallback
    }

    public func poll(now: Date) async throws -> ParseResult {
        do {
            let usage = try await client.fetchUsage()
            let journalCounts = journal.messageCounts(daysBack: 7, now: now)

            let todayStr = StatsCacheReader.dayString(from: now)
            let todayMsgs = journalCounts[todayStr] ?? 0
            let weekMsgs = journalCounts.values.reduce(0, +)

            let sessionWindow = LimitWindow(
                percentUsed: usage.sessionPercent,
                resetsAt: usage.sessionResetsAt,
                rawValueText: todayMsgs > 0 ? "\(todayMsgs) msgs" : nil
            )
            let weekWindow = LimitWindow(
                percentUsed: usage.weekPercent,
                resetsAt: usage.weekResetsAt,
                rawValueText: weekMsgs > 0 ? "\(weekMsgs) msgs" : nil
            )

            let thresholds = UsageThresholds.default
            let severity = UsageSeverity.highest(
                thresholds.severity(for: usage.sessionPercent),
                thresholds.severity(for: usage.weekPercent)
            )

            var snapshot = ClaudeUsageSnapshot(
                parserVersion: "claude-ai-api-1.0",
                createdAt: now,
                lastSuccessfulPollAt: now,
                source: SourceInfo(
                    cliPath: "claude.ai/api",
                    command: "GET /api/organizations/\(client.orgId)/usage"
                ),
                limits: LimitInfo(
                    currentSession: sessionWindow,
                    currentWeekAllModels: weekWindow
                ),
                state: SnapshotState(status: .ok, severity: severity)
            )
            snapshot.lastSuccessfulPollAt = now

            try store.writeLatest(snapshot)
            try store.clearLastError()

            return ParseResult(
                snapshot: snapshot,
                warnings: [],
                errors: [],
                rawHash: "",
                parserVersion: "claude-ai-api-1.0"
            )
        } catch {
            // Surface the API error as a warning, then fall back so the UI keeps showing data
            let warning = ParseWarning(field: "claude.ai API", message: String(describing: error))
            let fallbackResult = try await fallback.poll(now: now)
            return ParseResult(
                snapshot: fallbackResult.snapshot,
                warnings: [warning] + fallbackResult.warnings,
                errors: fallbackResult.errors,
                rawHash: fallbackResult.rawHash,
                parserVersion: fallbackResult.parserVersion
            )
        }
    }
}

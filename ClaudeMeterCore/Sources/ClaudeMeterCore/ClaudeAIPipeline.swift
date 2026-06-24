import Foundation

/// Pipeline that fetches utilization percentages from claude.ai/api/organizations/{orgId}/usage.
///
/// Falls back to `CachedSnapshotPipeline` on transient API errors. Auth failures do not fall back.
public struct ClaudeAIPipeline: ClaudeMeterPipeline {

    public let client: ClaudeAIUsageClient
    public let journal: JournalReader
    public let store: SnapshotStore
    public let fallback: any ClaudeMeterPipeline
    public let thresholds: UsageThresholds

    public init(
        client: ClaudeAIUsageClient,
        journal: JournalReader = JournalReader(),
        store: SnapshotStore,
        fallback: any ClaudeMeterPipeline,
        thresholds: UsageThresholds = .default
    ) {
        self.client = client
        self.journal = journal
        self.store = store
        self.fallback = fallback
        self.thresholds = thresholds
    }

    public func poll(now: Date) async throws -> ParseResult {
        let journal = self.journal
        let journalCounts = await Task.detached {
            journal.messageCounts(daysBack: 7, now: now)
        }.value

        do {
            let usage = try await client.fetchUsage()
            let todayStr = JournalReader.dayString(from: now)
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
            let opusWindow = usage.weekOpusPercent.map {
                LimitWindow(percentUsed: $0, resetsAt: usage.weekOpusResetsAt)
            }

            let severity = [usage.sessionPercent, usage.weekPercent, usage.weekOpusPercent]
                .reduce(UsageSeverity.unknown) {
                    UsageSeverity.highest($0, thresholds.severity(for: $1))
                }

            let snapshot = ClaudeUsageSnapshot(
                parserVersion: "claude-ai-api-1.0",
                createdAt: now,
                lastSuccessfulPollAt: now,
                source: SourceInfo(
                    cliPath: "claude.ai/api",
                    command: ClaudeAIUsageClient.redactedUsageCommand
                ),
                limits: LimitInfo(
                    currentSession: sessionWindow,
                    currentWeekAllModels: weekWindow,
                    currentWeekOpus: opusWindow
                ),
                state: SnapshotState(status: .ok, severity: severity)
            )

            try store.writeLatest(snapshot)
            try store.clearLastError()

            return ParseResult(
                snapshot: snapshot,
                warnings: [],
                errors: [],
                rawHash: "",
                parserVersion: "claude-ai-api-1.0"
            )
        } catch let error as ClaudeAIError where error.isAuthFailure {
            let message = error.localizedDescription
            try? store.writeLastError(LastErrorRecord(occurredAt: now, message: message))
            return ParseResult(
                snapshot: nil,
                warnings: [],
                errors: [ParseError(message)],
                rawHash: "",
                parserVersion: "claude-ai-api-1.0"
            )
        } catch {
            let warning = ParseWarning(
                field: "claude.ai API",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            let previousPollAt = try? store.readLatest()?.lastSuccessfulPollAt
            let fallbackResult = try await fallback.poll(now: now)

            var snapshot = fallbackResult.snapshot
            if var snap = snapshot {
                snap.lastSuccessfulPollAt = previousPollAt
                snap.state.isStale = true
                snapshot = snap
                try? store.writeLatest(snap)
            }

            return ParseResult(
                snapshot: snapshot,
                warnings: [warning] + fallbackResult.warnings,
                errors: fallbackResult.errors,
                rawHash: fallbackResult.rawHash,
                parserVersion: fallbackResult.parserVersion
            )
        }
    }
}

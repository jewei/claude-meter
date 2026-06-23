import Foundation

/// Primary pipeline that reads Claude Code's own rate-limit data via the statusline bridge.
///
/// Fallback order when stale (rate-limited to once per minute):
/// 1. Statusline bridge (`~/.claude-meter/statusline.json`)
/// 2. OAuth usage API (`GET /api/oauth/usage` with Bearer token)
/// 3. claude.ai usage API (`GET /api/organizations/{orgId}/usage` with sessionKey cookie)
public final class StatuslinePipeline: ClaudeMeterPipeline, @unchecked Sendable {

    private let fallback: any ClaudeMeterPipeline
    private let store: SnapshotStore
    private let thresholds: UsageThresholds
    private let stateQueue = DispatchQueue(label: "com.jewei.claudemeter.statusline-pipeline.state")
    private var lastFallbackPollAt: Date? = nil

    private let stalenessThreshold: TimeInterval = 60
    private let fallbackCooldown: TimeInterval = 60

    public init(
        fallback: any ClaudeMeterPipeline,
        store: SnapshotStore,
        thresholds: UsageThresholds = .default
    ) {
        self.fallback = fallback
        self.store = store
        self.thresholds = thresholds
    }

    public func poll(now: Date) async throws -> ParseResult {
        // Primary: use statusline bridge if data is fresh and contains rate limits.
        if StatuslineBridge.isDataFresh(maxAge: stalenessThreshold),
           let payload = try? StatuslineBridge.readData(),
           payload.fiveHour != nil || payload.sevenDay != nil
        {
            let snapshot = buildSnapshot(from: payload, now: now)
            try? store.writeLatest(snapshot)
            try? store.clearLastError()
            return ParseResult(
                snapshot: snapshot,
                warnings: [],
                errors: [],
                rawHash: String(payload.capturedAt.timeIntervalSince1970),
                parserVersion: "statusline-1.0"
            )
        }

        // Statusline is stale. Check if the fallback cooldown has elapsed.
        if markFallbackPollIfCooldownElapsed(now: now) {
            return try await fallback.poll(now: now)
        }

        // Within cooldown window — serve the last cached snapshot as stale.
        if let cached = try? store.readLatest() {
            var snap = cached
            snap.state.isStale = true
            return ParseResult(
                snapshot: snap,
                warnings: [ParseWarning(
                    field: "statusline",
                    message: "Statusline stale; next API check in \(secondsUntilNextFallback(now: now))s"
                )],
                errors: [],
                rawHash: "",
                parserVersion: snap.parserVersion
            )
        }

        // No cache either — call fallback unconditionally.
        markFallbackPoll(now: now)
        return try await fallback.poll(now: now)
    }

    private func secondsUntilNextFallback(now: Date) -> Int {
        guard let last = stateQueue.sync(execute: { lastFallbackPollAt }) else { return 0 }
        let remaining = fallbackCooldown - now.timeIntervalSince(last)
        return max(0, Int(remaining.rounded()))
    }

    private func markFallbackPollIfCooldownElapsed(now: Date) -> Bool {
        stateQueue.sync {
            let cooldownElapsed = lastFallbackPollAt.map { now.timeIntervalSince($0) >= fallbackCooldown } ?? true
            if cooldownElapsed {
                lastFallbackPollAt = now
            }
            return cooldownElapsed
        }
    }

    private func markFallbackPoll(now: Date) {
        stateQueue.sync {
            lastFallbackPollAt = now
        }
    }

    private func buildSnapshot(from payload: StatuslineBridge.StatuslinePayload, now: Date) -> ClaudeUsageSnapshot {
        let sessionWindow = payload.fiveHour.map { w in
            LimitWindow(percentUsed: w.usedPercentage, resetsAt: w.resetsAt)
        } ?? LimitWindow()

        let weekWindow = payload.sevenDay.map { w in
            LimitWindow(percentUsed: w.usedPercentage, resetsAt: w.resetsAt)
        } ?? LimitWindow()

        let severity = UsageSeverity.highest(
            thresholds.severity(for: payload.fiveHour?.usedPercentage),
            thresholds.severity(for: payload.sevenDay?.usedPercentage)
        )

        let sessionInfo: SessionInfo? = {
            guard payload.modelDisplayName != nil || payload.modelId != nil
                || payload.totalCostUsd != nil
            else { return nil }
            // Statusline exposes cwd/session identifiers; keep App Group snapshots widget-safe.
            return SessionInfo(
                activeModel: payload.modelDisplayName ?? payload.modelId,
                totalCostUsd: payload.totalCostUsd,
                totalApiDurationSeconds: payload.totalApiDurationMs.map { Int($0 / 1000) },
                codeLinesAdded: payload.codeLinesAdded,
                codeLinesRemoved: payload.codeLinesRemoved
            )
        }()

        return ClaudeUsageSnapshot(
            parserVersion: "statusline-1.0",
            createdAt: now,
            lastSuccessfulPollAt: payload.capturedAt,
            source: SourceInfo(
                cliPath: "statusline-bridge",
                cliVersion: payload.cliVersion,
                command: "~/.claude/settings.json statusLine"
            ),
            session: sessionInfo,
            limits: LimitInfo(
                currentSession: sessionWindow,
                currentWeekAllModels: weekWindow
            ),
            state: SnapshotState(status: .ok, severity: severity)
        )
    }
}

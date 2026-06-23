import Foundation

/// Primary pipeline that reads Claude Code's own rate-limit data via the statusline bridge.
///
/// When the bridge file is fresh (default: 2 min), uses its `rate_limits` data directly.
/// When stale, falls back to the inner pipeline (ClaudeAIPipeline or StatsCachePipeline)
/// but rate-limits those API calls to at most once per cooldown window (default: 1 min).
public final class StatuslinePipeline: ClaudeMeterPipeline, @unchecked Sendable {

    private let fallback: any ClaudeMeterPipeline
    private let store: SnapshotStore
    private let thresholds: UsageThresholds
    private var lastFallbackPollAt: Date? = nil

    /// Seconds before the statusline file is considered stale. Read from UserDefaults
    /// key `statuslineStalenessSeconds`; defaults to 120 (2 min).
    private var stalenessThreshold: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "statuslineStalenessSeconds")
        return v >= 30 ? v : 120
    }

    /// Minimum seconds between API fallback calls when statusline is stale. Read from
    /// UserDefaults key `statuslineFallbackCooldownSeconds`; minimum enforced at 60 (1 min).
    private var fallbackCooldown: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "statuslineFallbackCooldownSeconds")
        return max(60, v >= 60 ? v : 60)
    }

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
        let cooldownElapsed = lastFallbackPollAt.map { now.timeIntervalSince($0) >= fallbackCooldown } ?? true
        if cooldownElapsed {
            lastFallbackPollAt = now
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
        lastFallbackPollAt = now
        return try await fallback.poll(now: now)
    }

    private func secondsUntilNextFallback(now: Date) -> Int {
        guard let last = lastFallbackPollAt else { return 0 }
        let remaining = fallbackCooldown - now.timeIntervalSince(last)
        return max(0, Int(remaining.rounded()))
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
            guard payload.sessionId != nil || payload.sessionName != nil
                || payload.cwd != nil || payload.modelDisplayName != nil
                || payload.totalCostUsd != nil
            else { return nil }
            return SessionInfo(
                id: payload.sessionId,
                name: payload.sessionName,
                cwd: payload.cwd,
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

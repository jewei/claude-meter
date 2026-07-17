import Foundation

/// Primary pipeline that reads Claude Code's own rate-limit data via the statusline bridge.
///
/// Fallback order when stale (rate-limited to once per minute): statusline bridge,
/// OAuth usage API, then the last cached snapshot.
public final class StatuslinePipeline: ClaudeMeterPipeline, @unchecked Sendable {

    private let fallback: any ClaudeMeterPipeline
    private let store: SnapshotStore
    private let thresholds: UsageThresholds
    /// Account keys the user has disabled. Dropped from the read path so a disabled
    /// account neither shows in the popover nor wins active selection (the default
    /// `claude` account is never droppable). Injected at construction; a Settings
    /// toggle rebuilds the pipeline with a fresh set.
    private let disabledAccountKeys: Set<String>
    private let stateQueue = DispatchQueue(label: "com.jewei.claudemeter.statusline-pipeline.state")
    private var lastFallbackPollAt: Date? = nil
    /// Per-account activity tracker: a payload "signature" (cost/usage fields that
    /// only move on a real API call) plus the poll time it last *changed*. Drives
    /// active-account selection (see `selectActive`). Guarded by `stateQueue`.
    private var accountActivity: [String: AccountActivity] = [:]
    /// Previously-selected active account, used to break exact activity-time ties
    /// (cold start / pipeline rebuild, where every account is freshly seeded to
    /// `now`). Seeded from the last persisted snapshot so a relaunch keeps showing
    /// the account that was active, not a key/recency winner. Guarded by `stateQueue`.
    private var _lastActiveKey: String?

    private let stalenessThreshold: TimeInterval = 60
    private let fallbackCooldown: TimeInterval = 60

    public init(
        fallback: any ClaudeMeterPipeline,
        store: SnapshotStore,
        thresholds: UsageThresholds = .default,
        disabledAccountKeys: Set<String> = []
    ) {
        self.fallback = fallback
        self.store = store
        self.thresholds = thresholds
        self.disabledAccountKeys = disabledAccountKeys
        // Seed the active account from the last snapshot so a relaunch/rebuild keeps
        // the right account instead of momentarily resetting to a key/recency winner.
        self._lastActiveKey =
            (try? store.readLatest())?.accounts?.first(where: { $0.isActive })?.id
    }

    public func poll(now: Date) async throws -> ParseResult {
        // Primary: use the statusline bridge while any account is fresh. Group by
        // account so separate rate-limit buckets are never blended; the snapshot's
        // top-level fields mirror the most-recently-active account.
        let groups = Self.eligibleGroups(
            StatuslineBridge.readDataGrouped(maxAge: stalenessThreshold),
            disabled: disabledAccountKeys
        )
        if !groups.isEmpty {
            let snapshot = buildSnapshot(from: groups, now: now)
            try? store.writeLatest(snapshot)
            try? store.clearLastError()
            let freshest = groups.values.map(\.capturedAt).max() ?? now
            return ParseResult(
                snapshot: snapshot,
                warnings: [],
                errors: [],
                rawHash: String(freshest.timeIntervalSince1970),
                parserVersion: "statusline-1.0",
                sourceAttempts: [
                    SourceAttempt(source: .statusline, outcome: .selected, reason: .freshData)
                ]
            )
        }

        // Statusline produced nothing. Distinguish "bridge has never written data"
        // (fresh install, Claude Code not yet run) from "data exists but aged out" —
        // the diagnostics trail should not claim staleData when there's no data.
        let skipReason: SourceAttempt.Reason =
            StatuslineBridge.isDataFresh(maxAge: .infinity) ? .staleData : .noData

        // Check if the fallback cooldown has elapsed.
        if markFallbackPollIfCooldownElapsed(now: now) {
            return try await fallback.poll(now: now).prependingSourceAttempt(
                SourceAttempt(source: .statusline, outcome: .skipped, reason: skipReason))
        }

        // Within cooldown window — serve the last cached snapshot as stale.
        if let cached = try? store.readLatest() {
            var snap = cached
            snap.state.isStale = true
            return ParseResult(
                snapshot: snap,
                warnings: [
                    ParseWarning(
                        field: "statusline",
                        message:
                            "Statusline stale; next API check in \(secondsUntilNextFallback(now: now))s"
                    )
                ],
                errors: [],
                rawHash: "",
                parserVersion: snap.parserVersion,
                sourceAttempts: [
                    // The real skip cause (stale/no data), then why the cache was
                    // served instead of falling through to the next tier (cooldown).
                    SourceAttempt(source: .statusline, outcome: .skipped, reason: skipReason),
                    SourceAttempt(source: .cache, outcome: .selected, reason: .cooldown),
                ]
            )
        }

        // No cache either — call fallback unconditionally.
        markFallbackPoll(now: now)
        return try await fallback.poll(now: now).prependingSourceAttempt(
            SourceAttempt(source: .statusline, outcome: .skipped, reason: skipReason))
    }

    private func secondsUntilNextFallback(now: Date) -> Int {
        guard let last = stateQueue.sync(execute: { lastFallbackPollAt }) else { return 0 }
        let remaining = fallbackCooldown - now.timeIntervalSince(last)
        return max(0, Int(remaining.rounded()))
    }

    private func markFallbackPollIfCooldownElapsed(now: Date) -> Bool {
        stateQueue.sync {
            let cooldownElapsed =
                lastFallbackPollAt.map { now.timeIntervalSince($0) >= fallbackCooldown } ?? true
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

    /// Maps a bridge rate-limit window to a display window.
    ///
    /// Claude's rate-limit windows are *rolling*, so when a window's `resets_at`
    /// has passed it is expired: usage has reset to 0%. Open-but-idle Claude Code
    /// sessions keep re-emitting their last (now stale) snapshot every second, so
    /// without this check the meter shows a stale percentage (e.g. 25%) hours after
    /// the window actually reset. We can't predict the next rolling reset, so the
    /// countdown is dropped until activity resumes.
    static func displayWindow(for window: StatuslineBridge.RateLimitWindow?, now: Date)
        -> LimitWindow
    {
        guard let window else { return LimitWindow() }
        return LimitWindow(percentUsed: window.usedPercentage, resetsAt: window.resetsAt)
            .resolved(asOf: now)
    }

    /// Keeps only accounts the bridge actually surfaces: those with a window, and
    /// not user-disabled (the default `claude` account is never droppable). Pure,
    /// so the disabled-account behavior is unit-testable.
    static func eligibleGroups(
        _ groups: [String: StatuslineBridge.StatuslinePayload],
        disabled: Set<String>
    ) -> [String: StatuslineBridge.StatuslinePayload] {
        groups.filter { $0.value.fiveHour != nil || $0.value.sevenDay != nil }
            .filter {
                $0.key == StatuslineBridge.defaultAccountKey || !disabled.contains($0.key)
            }
    }

    /// Builds the snapshot for one poll: top-level fields mirror the active account,
    /// and `accounts` carries the per-account list when more than one is observed.
    private func buildSnapshot(
        from groups: [String: StatuslineBridge.StatuslinePayload], now: Date
    ) -> ClaudeUsageSnapshot {
        let activeKey = activeAccountKey(in: groups, now: now)
        let activePayload = groups[activeKey] ?? groups.values.first!
        var snapshot = buildSnapshot(from: activePayload, now: now)

        // Surface the per-account list when more than one account is active. A lone
        // *non-default* account is also surfaced (single element) so the UI can key
        // user name/plan overrides by its account key; a lone default `claude`
        // account stays byte-identical to the historical shape (`accounts == nil`).
        if groups.count > 1 {
            snapshot.accounts =
                groups
                .sorted {
                    let ra = StatuslineBridge.payloadRecency($0.value)
                    let rb = StatuslineBridge.payloadRecency($1.value)
                    if ra != rb { return ra > rb }
                    return $0.key < $1.key
                }
                .map { key, payload in
                    makeAccountUsage(
                        key: key, payload: payload, isActive: key == activeKey, now: now)
                }
        } else if activeKey != StatuslineBridge.defaultAccountKey {
            snapshot.accounts = [
                makeAccountUsage(key: activeKey, payload: activePayload, isActive: true, now: now)
            ]
        }
        return snapshot
    }

    private func buildSnapshot(from payload: StatuslineBridge.StatuslinePayload, now: Date)
        -> ClaudeUsageSnapshot
    {
        let fields = accountFields(from: payload, now: now)
        return ClaudeUsageSnapshot(
            parserVersion: "statusline-1.0",
            createdAt: now,
            lastSuccessfulPollAt: payload.capturedAt,
            source: SourceInfo(
                cliPath: "statusline-bridge",
                cliVersion: payload.cliVersion,
                command: "~/.claude/settings.json statusLine"
            ),
            session: fields.session,
            limits: fields.limits,
            state: SnapshotState(status: .ok, severity: fields.severity)
        )
    }

    private func makeAccountUsage(
        key: String,
        payload: StatuslineBridge.StatuslinePayload,
        isActive: Bool,
        now: Date
    ) -> AccountUsage {
        let fields = accountFields(from: payload, now: now)
        return AccountUsage(
            id: key,
            label: ConfigDirDiscovery.label(forKey: key),
            session: fields.session,
            limits: fields.limits,
            lastSuccessfulPollAt: payload.capturedAt,
            severity: fields.severity,
            isActive: isActive
        )
    }

    /// Maps one window-bearing payload to the display limits/session/severity shared
    /// by both the top-level snapshot and the per-account list.
    private func accountFields(from payload: StatuslineBridge.StatuslinePayload, now: Date)
        -> (limits: LimitInfo, session: SessionInfo?, severity: UsageSeverity)
    {
        let sessionWindow = Self.displayWindow(for: payload.fiveHour, now: now)
        let weekWindow = Self.displayWindow(for: payload.sevenDay, now: now)
        let opusWindow = payload.sevenDayOpus.map { Self.displayWindow(for: $0, now: now) }

        let severity = [sessionWindow.percentUsed, weekWindow.percentUsed, opusWindow?.percentUsed]
            .reduce(UsageSeverity.unknown) {
                UsageSeverity.highest($0, thresholds.severity(for: $1))
            }

        let sessionInfo: SessionInfo? = {
            guard
                payload.modelDisplayName != nil || payload.modelId != nil
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

        return (
            LimitInfo(
                currentSession: sessionWindow,
                currentWeekAllModels: weekWindow,
                currentWeekOpus: opusWindow
            ),
            sessionInfo,
            severity
        )
    }

    /// Per-account activity record: the activity signature and the poll time it last changed.
    struct AccountActivity: Equatable, Sendable {
        var signature: String
        var lastActiveAt: Date
    }

    /// Selects the most-recently-*active* account and returns the updated activity map.
    ///
    /// Why not file mtime or `resets_at`? The bridge rewrites *every* session file
    /// once a second (`refreshInterval: 1`), so an open-but-idle terminal looks just
    /// as "fresh" as the one you're prompting; and Claude's five-hour `resets_at`
    /// marks when each account's window *started*, not recent use — so an idle
    /// account whose window started later would wrongly win. Instead we diff each
    /// account's activity signature (cost / API duration / usage — fields that only
    /// move on a real API call) across polls: the account whose signature changed
    /// most recently is active; idle accounts keep their last-active time frozen.
    /// Ties (and first sight) fall back to window-reset recency, then key order.
    static func selectActive(
        groups: [String: StatuslineBridge.StatuslinePayload],
        prior: [String: AccountActivity],
        sticky: String?,
        now: Date
    ) -> (key: String, activity: [String: AccountActivity]) {
        var activity: [String: AccountActivity] = [:]
        for (key, payload) in groups {
            let signature = activitySignature(payload)
            if let previous = prior[key], previous.signature == signature {
                activity[key] = AccountActivity(
                    signature: signature, lastActiveAt: previous.lastActiveAt)
            } else {
                activity[key] = AccountActivity(signature: signature, lastActiveAt: now)
            }
        }

        let keys = groups.keys.sorted()  // deterministic base order for full ties
        guard var best = keys.first else {
            return (StatuslineBridge.defaultAccountKey, activity)
        }
        // Highest last-active time; exact ties broken by the previously-active
        // (sticky) account, then window-reset recency, then key order.
        func isBetter(_ candidate: String, than current: String) -> Bool {
            let a = activity[candidate]!.lastActiveAt
            let b = activity[current]!.lastActiveAt
            if a != b { return a > b }
            if candidate == sticky && current != sticky { return true }
            if current == sticky && candidate != sticky { return false }
            let ra = StatuslineBridge.payloadRecency(groups[candidate]!)
            let rb = StatuslineBridge.payloadRecency(groups[current]!)
            if ra != rb { return ra > rb }
            return candidate < current
        }
        for key in keys.dropFirst() where isBetter(key, than: best) { best = key }
        return (best, activity)
    }

    /// Fields that tick on real API activity; stable while a session is idle (even
    /// as its file is rewritten every second). Any change marks the account active.
    static func activitySignature(_ p: StatuslineBridge.StatuslinePayload) -> String {
        let cost: String = p.totalCostUsd.map { "\($0)" } ?? "-"
        let api: String = p.totalApiDurationMs.map { "\($0)" } ?? "-"
        let five: String = (p.fiveHour?.usedPercentage).map { "\($0)" } ?? "-"
        let seven: String = (p.sevenDay?.usedPercentage).map { "\($0)" } ?? "-"
        let added: String = p.codeLinesAdded.map { "\($0)" } ?? "-"
        let removed: String = p.codeLinesRemoved.map { "\($0)" } ?? "-"
        return [cost, api, five, seven, added, removed].joined(separator: "|")
    }

    private func activeAccountKey(
        in groups: [String: StatuslineBridge.StatuslinePayload], now: Date
    ) -> String {
        stateQueue.sync {
            let (key, activity) = Self.selectActive(
                groups: groups, prior: accountActivity, sticky: _lastActiveKey, now: now)
            accountActivity = activity
            _lastActiveKey = key
            return key
        }
    }
}

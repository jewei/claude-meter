import Foundation
import MeterDomain
import MeterPlatform
import Observation

/// The only owner of provider readings and token histories.
///
/// Each provider has at most one quota refresh and one history refresh in flight. A newer
/// refresh supersedes only its own provider; only the newest refresh can publish. Quota and
/// history are independent: each has its own due rule, token, and deadline, so a due history
/// never starts a quota request. Disabling a provider cancels its work, removes its readings,
/// and rejects late results. See `docs/architecture.md` for the full lifecycle.
@MainActor @Observable
public final class UsageStore {
    public nonisolated static let fetchDeadline: Duration = .seconds(90)
    public nonisolated static let historyDeadline: Duration = .seconds(20)
    /// A history is due again when its last attempt is at least this old.
    public nonisolated static let historyMaxAge: TimeInterval = 240

    public private(set) var readings: [ProviderID: Reading<ProviderUsage>] = [:]
    public private(set) var histories: [ProviderID: Reading<ProviderTokenHistory>] = [:]
    public private(set) var refreshing: Set<ProviderID> = []
    public private(set) var refreshingHistory: Set<ProviderID> = []

    @ObservationIgnored private let providers: [ProviderID: any UsageProvider]
    @ObservationIgnored private let historyProviders: [ProviderID: any TokenHistoryProvider]
    @ObservationIgnored private let archive: ReadingArchive?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: @Sendable () -> Calendar
    @ObservationIgnored private let quotaLimit: Duration
    @ObservationIgnored private let historyLimit: Duration
    @ObservationIgnored private var enabled: Set<ProviderID> = []
    @ObservationIgnored private var quotaJobs: [ProviderID: Job] = [:]
    @ObservationIgnored private var historyJobs: [ProviderID: Job] = [:]
    /// When each history refresh last started, and in which time zone.
    @ObservationIgnored private var historyAttempts: [ProviderID: Attempt] = [:]

    private struct Job {
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct Attempt {
        let date: Date
        let timeZoneID: String
    }

    /// - Parameters:
    ///   - now: The clock for reading ages and history attempts.
    ///   - calendar: The calendar for the local day of token history. Read on each use, so a
    ///     time-zone change applies at once.
    ///   - fetchDeadline: The safety net for one quota refresh, reconcile included.
    ///   - historyDeadline: The limit for one history refresh.
    public init(
        providers: [any UsageProvider],
        historyProviders: [any TokenHistoryProvider] = [],
        archive: ReadingArchive? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: @escaping @Sendable () -> Calendar = { Calendar.current },
        fetchDeadline: Duration = UsageStore.fetchDeadline,
        historyDeadline: Duration = UsageStore.historyDeadline
    ) {
        self.quotaLimit = fetchDeadline
        self.historyLimit = historyDeadline
        self.providers = Dictionary(
            providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.historyProviders = Dictionary(
            historyProviders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.archive = archive
        self.now = now
        self.calendar = calendar
    }

    /// Shows readings saved by an earlier launch until the first refresh replaces them.
    public func restore(_ saved: [ProviderID: ProviderUsage]) {
        for (id, usage) in saved where readings[id] == nil {
            guard let observedAt = usage.observedAt else { continue }
            readings[id] = .current(usage, observedAt: observedAt)
        }
    }

    /// Sets the providers that may refresh. Disabling clears the provider's readings.
    public func setEnabled(_ ids: Set<ProviderID>) {
        let removed = enabled.subtracting(ids)
        enabled = ids.filter { providers[$0] != nil }
        for id in removed {
            cancel([id])
            readings[id] = nil
            histories[id] = nil
            historyAttempts[id] = nil
            archive?.record(nil, for: id)
        }
    }

    /// Refreshes quota for `ids`, and history for those whose history is due, or for all of
    /// them with `forceHistory`.
    public func refresh(_ ids: Set<ProviderID>, forceHistory: Bool = false) async {
        await refresh(quota: ids, history: forceHistory ? ids : ids.filter(historyNeedsRefresh))
    }

    /// Refreshes quota for `quota` and token history for `history`, whether due or not.
    /// Starts every job before waiting, so one slow provider never delays another. Cancelling
    /// the caller cancels only these refreshes, never a newer one.
    public func refresh(quota: Set<ProviderID>, history: Set<ProviderID>) async {
        var tasks = targets(quota).compactMap { startQuota($0, fetches: true) }
        tasks += targets(history).compactMap(startHistory)
        await wait(for: tasks)
    }

    /// Applies account and login changes from local reads only: each provider's `reconcile`
    /// runs, and a changed value is published and saved. Sends no request. Supersedes a quota
    /// refresh in flight for these ids. Use it when refreshing cannot run, for example while
    /// updates are paused, so a removed account or a changed login disappears at once.
    public func reconcile(_ ids: Set<ProviderID>) async {
        let withReadings = targets(ids).filter { readings[$0] != nil }
        await wait(for: withReadings.compactMap { startQuota($0, fetches: false) })
    }

    private func wait(for tasks: [Task<Void, Never>]) async {
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }

    /// Cancels work without changing any reading.
    public func cancel(_ ids: Set<ProviderID> = Set(ProviderID.allCases)) {
        for id in ids {
            quotaJobs.removeValue(forKey: id)?.task.cancel()
            historyJobs.removeValue(forKey: id)?.task.cancel()
            refreshing.remove(id)
            refreshingHistory.remove(id)
        }
    }

    /// Whether the quota reading of `id` is missing, failed, stale, or at least `maxAge` seconds
    /// old. History never makes quota due; it has its own rule (``historyNeedsRefresh(_:)``).
    public func needsRefresh(_ id: ProviderID, maxAge: TimeInterval) -> Bool {
        guard enabled.contains(id) else { return false }
        return readings[id]?.needsRefresh(at: now(), maxAge: maxAge) ?? true
    }

    /// Whether the token history of `id` is due: it was never read, the local day or time zone
    /// changed since the last attempt, or that attempt is at least ``historyMaxAge`` old. A
    /// failed history waits for the same age, so a scan that keeps failing does not run again
    /// on every popover open.
    public func historyNeedsRefresh(_ id: ProviderID) -> Bool {
        guard enabled.contains(id), historyProviders[id] != nil, !refreshingHistory.contains(id)
        else { return false }
        guard let attempt = historyAttempts[id] else { return true }
        let date = now()
        let calendar = calendar()
        if attempt.timeZoneID != calendar.timeZone.identifier
            || !calendar.isDate(attempt.date, inSameDayAs: date)
        {
            return true
        }
        let age = date.timeIntervalSince(attempt.date)
        return !age.isFinite || age < 0 || age >= Self.historyMaxAge
    }

    private func targets(_ ids: Set<ProviderID>) -> [ProviderID] {
        ids.intersection(enabled).sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Quota

    /// Starts a quota job: reconcile, then fetch when `fetches` is true. A reconcile-only job
    /// is local and short, so it does not count as refreshing.
    private func startQuota(_ id: ProviderID, fetches: Bool) -> Task<Void, Never>? {
        guard let provider = providers[id] else { return nil }
        quotaJobs[id]?.task.cancel()
        let token = UUID()
        let previous = readings[id]?.value
        if fetches {
            refreshing.insert(id)
        } else {
            refreshing.remove(id)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runQuota(provider, token: token, previous: previous, fetches: fetches)
        }
        quotaJobs[id] = Job(token: token, task: task)
        return task
    }

    private func runQuota(
        _ provider: any UsageProvider, token: UUID, previous: ProviderUsage?, fetches: Bool
    ) async {
        let id = provider.id
        defer { finishQuota(id, token: token) }
        // One deadline covers reconcile and fetch, and holds even when the provider ignores
        // cancellation, so a stuck provider never stays "refreshing".
        let deadline = ContinuousClock.now + quotaLimit
        do {
            let reconciled = try await SafetyDeadline.run(until: deadline, limit: quotaLimit) {
                await provider.reconcile(previous)
            }
            guard isCurrentQuota(id, token) else { return }
            if reconciled != previous { applyReconciled(reconciled, for: id) }
            guard fetches else { return }
            let usage = try await SafetyDeadline.run(until: deadline, limit: quotaLimit) {
                try await provider.fetch(previous: reconciled)
            }
            guard isCurrentQuota(id, token) else { return }
            publish(usage, for: id)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentQuota(id, token) else { return }
            recordFailure(ProviderError(wrapping: error), for: id)
        }
    }

    private func isCurrentQuota(_ id: ProviderID, _ token: UUID) -> Bool {
        quotaJobs[id]?.token == token && enabled.contains(id) && !Task.isCancelled
    }

    private func finishQuota(_ id: ProviderID, token: UUID) {
        guard quotaJobs[id]?.token == token else { return }
        quotaJobs[id] = nil
        refreshing.remove(id)
    }

    /// Keeps the outer state (current, stale, or failed) and replaces only the value. A value
    /// with no observation is removed, unless the reading failed and its issue still applies.
    /// The archive changes at once too, so a removed login never returns at the next launch,
    /// even when the fetch that follows is cancelled.
    private func applyReconciled(_ usage: ProviderUsage?, for id: ProviderID) {
        archive?.record(usage, for: id)
        switch (readings[id], usage, usage?.observedAt) {
        case (.failed(let issue, _), _, _):
            readings[id] = .failed(issue, partial: usage)
        case (.stale(_, _, let issue), let usage?, let observedAt?):
            readings[id] = .stale(usage, observedAt: observedAt, issue: issue)
        case (_, let usage?, let observedAt?):
            readings[id] = .current(usage, observedAt: observedAt)
        default:
            readings[id] = nil
        }
    }

    private func publish(_ usage: ProviderUsage, for id: ProviderID) {
        if let observedAt = usage.observedAt {
            readings[id] = .current(usage, observedAt: observedAt)
        } else {
            let issue =
                usage.accounts.lazy.compactMap(\.issue).first
                ?? UsageIssue("\(id.displayName) reported no usage.")
            readings[id] = .failed(issue, partial: usage)
        }
        archive?.record(usage, for: id)
    }

    private func recordFailure(_ failure: ProviderError, for id: ProviderID) {
        if failure.keepsLastReading, let value = readings[id]?.value,
            let observedAt = readings[id]?.observedAt
        {
            readings[id] = .stale(value, observedAt: observedAt, issue: failure.issue)
        } else {
            readings[id] = .failed(failure.issue)
            archive?.record(nil, for: id)
        }
    }

    // MARK: - History

    private func startHistory(_ id: ProviderID) -> Task<Void, Never>? {
        guard let source = historyProviders[id] else { return nil }
        historyJobs[id]?.task.cancel()
        let token = UUID()
        let date = now()
        historyAttempts[id] = Attempt(date: date, timeZoneID: calendar().timeZone.identifier)
        refreshingHistory.insert(id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runHistory(source, token: token, now: date)
        }
        historyJobs[id] = Job(token: token, task: task)
        return task
    }

    private func runHistory(_ source: any TokenHistoryProvider, token: UUID, now date: Date) async {
        let id = source.id
        defer { finishHistory(id, token: token) }
        do {
            let limit = historyLimit
            let history = try await SafetyDeadline.run(until: .now + limit, limit: limit) {
                try await source.history(now: date)
            }
            guard isCurrentHistory(id, token) else { return }
            histories[id] = .current(history, observedAt: history.observedAt)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentHistory(id, token) else { return }
            let failure = ProviderError(wrapping: error)
            if failure.keepsLastReading, let value = histories[id]?.value,
                let observedAt = histories[id]?.observedAt
            {
                histories[id] = .stale(value, observedAt: observedAt, issue: failure.issue)
            } else {
                histories[id] = .failed(failure.issue)
            }
        }
    }

    private func isCurrentHistory(_ id: ProviderID, _ token: UUID) -> Bool {
        historyJobs[id]?.token == token && enabled.contains(id) && !Task.isCancelled
    }

    private func finishHistory(_ id: ProviderID, token: UUID) {
        guard historyJobs[id]?.token == token else { return }
        historyJobs[id] = nil
        refreshingHistory.remove(id)
    }
}

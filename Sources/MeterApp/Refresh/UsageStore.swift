import Foundation
import MeterDomain
import MeterPlatform
import Observation

/// The only owner of provider readings and token histories.
///
/// Each provider has at most one quota refresh and one history refresh in flight. A newer
/// refresh supersedes only its own provider; only the newest refresh can publish. Disabling a
/// provider cancels its work, removes its readings, and rejects late results. See
/// `docs/architecture.md` for the full lifecycle.
@MainActor @Observable
public final class UsageStore {
    public static let fetchDeadline: Duration = .seconds(90)
    public static let historyDeadline: Duration = .seconds(20)
    /// A history older than this is refreshed with the next quota refresh.
    public static let historyMaxAge: TimeInterval = 240

    public private(set) var readings: [ProviderID: Reading<ProviderUsage>] = [:]
    public private(set) var histories: [ProviderID: Reading<ProviderTokenHistory>] = [:]
    public private(set) var refreshing: Set<ProviderID> = []
    public private(set) var refreshingHistory: Set<ProviderID> = []

    @ObservationIgnored private let providers: [ProviderID: any UsageProvider]
    @ObservationIgnored private let historyProviders: [ProviderID: any TokenHistoryProvider]
    @ObservationIgnored private let archive: ReadingArchive?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var enabled: Set<ProviderID> = []
    @ObservationIgnored private var quotaJobs: [ProviderID: Job] = [:]
    @ObservationIgnored private var historyJobs: [ProviderID: Job] = [:]

    private struct Job {
        let token: UUID
        let task: Task<Void, Never>
    }

    public init(
        providers: [any UsageProvider],
        historyProviders: [any TokenHistoryProvider] = [],
        archive: ReadingArchive? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.providers = Dictionary(
            providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.historyProviders = Dictionary(
            historyProviders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.archive = archive
        self.now = now
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
            archive?.record(nil, for: id)
        }
    }

    /// Refreshes quota for `ids` and history for those whose history is due. Starts every
    /// provider before waiting, so one slow provider never delays another. Cancelling the
    /// caller cancels only these refreshes, never a newer one.
    public func refresh(_ ids: Set<ProviderID>, forceHistory: Bool = false) async {
        let targets = ids.intersection(enabled).sorted { $0.rawValue < $1.rawValue }
        var tasks = targets.compactMap(startQuota)
        tasks += targets.filter { forceHistory || historyIsDue($0) }.compactMap(startHistory)
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

    /// Whether `id` should refresh when the reading may be at most `maxAge` seconds old.
    public func needsRefresh(_ id: ProviderID, maxAge: TimeInterval) -> Bool {
        guard enabled.contains(id) else { return false }
        let quotaDue = readings[id]?.needsRefresh(at: now(), maxAge: maxAge) ?? true
        return quotaDue || historyIsDue(id)
    }

    // MARK: - Quota

    private func startQuota(_ id: ProviderID) -> Task<Void, Never>? {
        guard let provider = providers[id] else { return nil }
        quotaJobs[id]?.task.cancel()
        let token = UUID()
        let previous = readings[id]?.value
        refreshing.insert(id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runQuota(provider, token: token, previous: previous)
        }
        quotaJobs[id] = Job(token: token, task: task)
        return task
    }

    private func runQuota(
        _ provider: any UsageProvider, token: UUID, previous: ProviderUsage?
    ) async {
        let id = provider.id
        defer { finishQuota(id, token: token) }
        let reconciled = await provider.reconcile(previous)
        guard isCurrentQuota(id, token) else { return }
        if reconciled != previous { applyReconciled(reconciled, for: id) }
        do {
            let usage = try await withDeadline(Self.fetchDeadline) {
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

    /// Keeps the outer state (current or stale) and replaces only the value. A value with no
    /// observation is removed; the fetch that follows decides what to show.
    private func applyReconciled(_ usage: ProviderUsage?, for id: ProviderID) {
        guard let usage, let observedAt = usage.observedAt else {
            readings[id] = nil
            return
        }
        if case .stale(_, _, let issue) = readings[id] {
            readings[id] = .stale(usage, observedAt: observedAt, issue: issue)
        } else {
            readings[id] = .current(usage, observedAt: observedAt)
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

    private func historyIsDue(_ id: ProviderID) -> Bool {
        guard historyProviders[id] != nil, !refreshingHistory.contains(id) else { return false }
        guard let reading = histories[id] else { return true }
        let date = now()
        let calendar = Calendar.current
        if let history = reading.value,
            history.timeZoneID != calendar.timeZone.identifier
                || !calendar.isDate(history.observedAt, inSameDayAs: date)
        {
            return true
        }
        return reading.needsRefresh(at: date, maxAge: Self.historyMaxAge)
    }

    private func startHistory(_ id: ProviderID) -> Task<Void, Never>? {
        guard let source = historyProviders[id] else { return nil }
        historyJobs[id]?.task.cancel()
        let token = UUID()
        refreshingHistory.insert(id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runHistory(source, token: token)
        }
        historyJobs[id] = Job(token: token, task: task)
        return task
    }

    private func runHistory(_ source: any TokenHistoryProvider, token: UUID) async {
        let id = source.id
        defer { finishHistory(id, token: token) }
        let date = now()
        do {
            let history = try await withDeadline(Self.historyDeadline) {
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

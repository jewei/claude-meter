import Foundation
import MeterDomain
import MeterPlatform

/// Token history: the same lifecycle as quota, with its own due rule, token, and deadline
/// (`docs/architecture.md`).
extension UsageStore {
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

    func startHistory(_ id: ProviderID) -> Task<Void, Never>? {
        guard let source = historyProviders[id] else { return nil }
        historyJobs[id]?.task.cancel()
        let token = UUID()
        let attempt = Attempt(date: now(), timeZoneID: calendar().timeZone.identifier)
        refreshingHistory.insert(id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runHistory(source, token: token, attempt: attempt)
        }
        historyJobs[id] = Job(token: token, task: task)
        return task
    }

    /// The attempt counts only when the read ends with a result or a failure, so a cancelled
    /// read (sleep, pause) leaves the history due, as a cancelled quota refresh is.
    private func runHistory(_ source: any TokenHistoryProvider, token: UUID, attempt: Attempt)
        async
    {
        let id = source.id
        let date = attempt.date
        defer { finishHistory(id, token: token) }
        let start = ContinuousClock.now
        let limit = historyLimit
        do {
            // The same lifecycle as quota: drop a held history whose login changed at once,
            // then read with the held history as `previous`.
            let previous = histories[id]?.value
            let reconciled = try await withDeadline(limit) { await source.reconcile(previous) }
            guard isCurrentHistory(id, token) else { return }
            if reconciled != previous { applyReconciledHistory(reconciled, for: id) }
            let remaining = limit - (ContinuousClock.now - start)
            let history = try await withDeadline(max(remaining, .zero)) {
                try await source.history(now: date, previous: reconciled)
            }
            guard isCurrentHistory(id, token) else { return }
            historyAttempts[id] = attempt
            histories[id] = .current(history, observedAt: history.observedAt)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentHistory(id, token) else { return }
            historyAttempts[id] = attempt
            let failure = Self.failure(error, provider: id, isHistory: true)
            if failure.keepsLastReading, let value = histories[id]?.value,
                let observedAt = histories[id]?.observedAt
            {
                histories[id] = .stale(value, observedAt: observedAt, issue: failure.issue)
            } else {
                histories[id] = .failed(failure.issue)
            }
        }
    }

    /// Keeps the outer state and replaces the value; nil removes the history. As for quota,
    /// the date is the reconciled value's own.
    private func applyReconciledHistory(_ history: ProviderTokenHistory?, for id: ProviderID) {
        guard let history else {
            histories[id] = nil
            return
        }
        if case .stale(_, _, let issue) = histories[id] {
            histories[id] = .stale(history, observedAt: history.observedAt, issue: issue)
        } else {
            histories[id] = .current(history, observedAt: history.observedAt)
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

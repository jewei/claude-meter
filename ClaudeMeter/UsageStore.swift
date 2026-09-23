import ClaudeMeterCore
import Combine
import Foundation

/// Owns all provider quota state. RefreshScheduler decides when a cycle is admitted.
/// MainActor orders acceptance and publication. Provider I/O runs off-main.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var readings: [ProviderID: ReadingState<ProviderSnapshot>] = [:]
    @Published private(set) var refreshing: Set<ProviderID> = []

    private let providers: [ProviderID: any UsageProvider]
    private let timeoutSeconds: TimeInterval
    private var enabled: Set<ProviderID> = []

    private struct Refresh: Sendable {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var active: [ProviderID: Refresh] = [:]

    init(providers: [any UsageProvider], timeoutSeconds: TimeInterval = 60) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.timeoutSeconds = timeoutSeconds
    }

    /// Source diagnostics can inspect the explicit provider boundary, never a wire reading.
    func provider(for id: ProviderID) -> (any UsageProvider)? { providers[id] }

    deinit {
        for refresh in active.values { refresh.task.cancel() }
    }

    func reading(for id: ProviderID) -> ReadingState<ProviderSnapshot>? { readings[id] }

    func setEnabled(_ id: ProviderID, enabled: Bool) {
        guard providers[id] != nil else { return }
        if enabled {
            self.enabled.insert(id)
        } else {
            self.enabled.remove(id)
            cancel([id])
            readings.removeValue(forKey: id)
        }
    }

    /// Starts all admitted providers before waiting. A newer request for one
    /// provider supersedes only that provider. Other providers remain independent.
    func refresh(_ providers: Set<ProviderID>, now: Date = Date()) async {
        guard !Task.isCancelled else { return }
        let requests = providers.intersection(enabled).compactMap { start($0, now: now) }
        await withTaskCancellationHandler {
            for request in requests { await request.task.value }
        } onCancel: {
            // Cancel only this caller's tasks, never a newer refresh's task.
            for request in requests { request.task.cancel() }
        }
    }

    /// Cancels work without turning the existing reading into a failure.
    func cancel(_ providers: Set<ProviderID> = Set(ProviderID.allCases)) {
        for id in providers {
            active.removeValue(forKey: id)?.task.cancel()
            refreshing.remove(id)
        }
    }

    private func start(_ id: ProviderID, now: Date) -> Refresh? {
        guard let provider = providers[id] else { return nil }
        cancel([id])
        let token = UUID()
        let timeout = timeoutSeconds
        let previous = readings[id]?.value
        refreshing.insert(id)
        let task = Task { [weak self] in
            defer { self?.endRefresh(id, token: token) }
            do {
                guard self?.isCurrent(id, token: token) == true else { return }
                let reconciled = try await provider.validatePrevious(
                    previous, now: now, refreshID: token)
                guard self?.isCurrent(id, token: token) == true else { return }
                // Simple providers return the same value. Preserve its outer error/freshness.
                if reconciled != previous {
                    if let reconciled {
                        self?.publish(reconciled, id: id)
                    } else {
                        self?.readings.removeValue(forKey: id)
                    }
                }
                guard self?.isCurrent(id, token: token) == true else { return }
                let snapshot: ProviderSnapshot
                if provider.ownsDeadline {
                    snapshot = try await provider.fetch(
                        now: now, previous: reconciled, refreshID: token)
                } else {
                    snapshot = try await Timeout.run(seconds: timeout) {
                        try await provider.fetch(now: now, previous: reconciled, refreshID: token)
                    }
                }
                guard self?.isCurrent(id, token: token) == true else { return }
                provider.didAccept(snapshot, refreshID: token)
                self?.publish(snapshot, id: id)
                self?.endRefresh(id, token: token)
                // Acceptance is final. A later refresh or cancellation cannot revoke it.
                await provider.waitForPersistence()
            } catch {
                guard self?.isCurrent(id, token: token) == true,
                    !(error is CancellationError)
                else { return }
                self?.recordFailure(error, id: id)
            }
        }
        let refresh = Refresh(token: token, task: task)
        active[id] = refresh
        return refresh
    }

    private func isCurrent(_ id: ProviderID, token: UUID) -> Bool {
        active[id]?.token == token && enabled.contains(id) && !Task.isCancelled
    }

    private func endRefresh(_ id: ProviderID, token: UUID) {
        guard active[id]?.token == token else { return }
        active.removeValue(forKey: id)
        refreshing.remove(id)
    }

    private func recordFailure(_ error: any Error, id: ProviderID) {
        let failure = error as? UsageProviderFailure ?? UsageProviderFailure(error)
        let previous = readings[id]
        if failure.retainsLastGood, let value = previous?.value,
            let polledAt = previous?.lastPolledAt
        {
            readings[id] = .stale(value: value, polledAt: polledAt, error: failure.message)
        } else {
            readings[id] = .failed(error: failure.message, lastPolledAt: previous?.lastPolledAt)
        }
    }

    private func publish(_ snapshot: ProviderSnapshot, id: ProviderID) {
        if snapshot.accounts.contains(where: { $0.observedAt != nil }) {
            readings[id] = .current(value: snapshot, polledAt: snapshot.fetchedAt)
        } else {
            readings[id] = .failed(
                error: snapshot.accounts.compactMap(\.lastError).first ?? "No usage reading.",
                lastPolledAt: nil, value: snapshot)
        }
    }

}

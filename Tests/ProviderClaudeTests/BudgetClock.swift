import Foundation
import MeterPlatform

/// The clock of the automatic refresh budget in tests. It moves only in ``elapse(_:)``, so a
/// busy machine can never end the budget or the limit of an account: a sleeper wakes only
/// when a test moves the clock past its deadline.
final class BudgetClock: Sendable {
    private struct Sleeper: Sendable {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var now = ContinuousClock.now
        var sleepers: [Sleeper] = []
        /// Sleepers that were cancelled before they started to wait.
        var cancelled: Set<UUID> = []
    }

    private let state = Locked(State())

    var now: ContinuousClock.Instant { state.value.now }

    /// Moves the clock by `duration`, and wakes every sleeper whose deadline it reached.
    func elapse(_ duration: Duration) {
        let woken = state.withLock { state -> [Sleeper] in
            state.now += duration
            let now = state.now
            defer { state.sleepers.removeAll { $0.deadline <= now } }
            return state.sleepers.filter { $0.deadline <= now }
        }
        for sleeper in woken { sleeper.continuation.resume() }
    }

    /// Returns when the clock reaches `deadline`. Throws `CancellationError` when the caller is
    /// cancelled first.
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        let state = state
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { state -> Result<Void, any Error>? in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(
                        Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

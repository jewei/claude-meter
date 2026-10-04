import Foundation
import MeterPlatform

/// Runs work that must end by a deadline, even when the work ignores cancellation.
///
/// `withDeadline` cancels its operation at the limit but then waits for it to return, so a
/// provider that never checks for cancellation could hold a refresh forever. Here the operation
/// runs in its own task, and the caller resumes at the deadline or on cancellation, whichever
/// comes first. The abandoned task is cancelled and its late result is dropped.
enum SafetyDeadline {
    /// Returns the operation's result, or throws ``TimeoutError`` at `deadline` and
    /// `CancellationError` when the caller is cancelled. `limit` names the deadline in the
    /// timeout message.
    static func run<Value: Sendable>(
        until deadline: ContinuousClock.Instant, limit: Duration,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let outcome = Outcome<Value>()
        let work = Task {
            do {
                outcome.finish(.success(try await operation()))
            } catch {
                outcome.finish(.failure(error))
            }
        }
        let timer = Task {
            guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else {
                return
            }
            outcome.finish(.failure(TimeoutError(limit: limit)))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { outcome.install($0) }
        } onCancel: {
            outcome.finish(.failure(CancellationError()))
        }
    }

    /// Resumes the caller once, with the first of result, timeout, or cancellation.
    private final class Outcome<Value: Sendable>: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<Value, any Error>?
            var early: Result<Value, any Error>?
            var isFinished = false
        }

        private let state = Locked(State())

        func install(_ continuation: CheckedContinuation<Value, any Error>) {
            let early = state.withLock { state -> Result<Value, any Error>? in
                guard let early = state.early else {
                    state.continuation = continuation
                    return nil
                }
                return early
            }
            if let early { continuation.resume(with: early) }
        }

        func finish(_ result: Result<Value, any Error>) {
            let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
                guard !state.isFinished else { return nil }
                state.isFinished = true
                guard let continuation = state.continuation else {
                    state.early = result
                    return nil
                }
                state.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
        }
    }
}

import Foundation

/// Work did not finish within its time limit.
public struct TimeoutError: Error, LocalizedError, Equatable, Sendable {
    public let limit: Duration

    public init(limit: Duration) {
        self.limit = limit
    }

    public var errorDescription: String? {
        "Timed out after \(limit.formatted(.units(allowed: [.seconds], width: .narrow)))."
    }
}

/// Runs `operation` and returns its result, or throws ``TimeoutError`` when `limit` passes,
/// or `CancellationError` when the caller is cancelled. Errors of `operation` pass through.
///
/// The caller never waits past the limit, also when `operation` ignores cancellation: the
/// operation runs in its own task, which is cancelled at the limit and left to end by itself.
/// It inherits the caller's priority and task-local values. Wrap blocking calls, such as file
/// or Keychain reads, in ``BlockingIO/run(timeout:_:)`` instead, because they hold a thread.
public func withDeadline<Value: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withDeadline(limit, timer: { try await Task.sleep(for: limit) }, operation)
}

/// Like ``withDeadline(_:_:)``, but `timer` decides when the limit has passed: it returns
/// then, and throws when it is cancelled. Tests pass one that returns at a known point, so
/// load on the machine cannot end the limit. `limit` only names the limit in the error.
public func withDeadline<Value: Sendable>(
    _ limit: Duration,
    timer: @escaping @Sendable () async throws -> Void,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    let race = DeadlineRace<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            // A caller cancelled before this point already has its error. Nothing starts.
            guard race.install(continuation) else { return }
            race.attach(
                Task {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                })
            race.attach(
                Task {
                    do {
                        try await timer()
                    } catch {
                        return  // Cancelled: the race finished first.
                    }
                    race.finish(.failure(TimeoutError(limit: limit)))
                })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Resumes the caller once, with whichever of the operation, the timer, or the caller's
/// cancellation comes first, and then cancels the tasks that lost.
private final class DeadlineRace<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Value, any Error>?
        var early: Result<Value, any Error>?
        var isFinished = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Locked(State())

    /// Returns false when the race finished before the caller started to wait. The
    /// continuation is then resumed at once, and no task must start.
    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        let early = state.withLock { state -> Result<Value, any Error>? in
            guard let early = state.early else {
                state.continuation = continuation
                return nil
            }
            return early
        }
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    /// Keeps `task` to cancel when the race finishes, or cancels it now if it already has.
    func attach(_ task: Task<Void, Never>) {
        let isFinished = state.withLock { state in
            if !state.isFinished { state.tasks.append(task) }
            return state.isFinished
        }
        if isFinished { task.cancel() }
    }

    func finish(_ result: Result<Value, any Error>) {
        let (continuation, tasks) = state.withLock {
            state -> (CheckedContinuation<Value, any Error>?, [Task<Void, Never>]) in
            guard !state.isFinished else { return (nil, []) }
            state.isFinished = true
            defer {
                state.tasks = []
                state.continuation = nil
            }
            if state.continuation == nil { state.early = result }
            return (state.continuation, state.tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}

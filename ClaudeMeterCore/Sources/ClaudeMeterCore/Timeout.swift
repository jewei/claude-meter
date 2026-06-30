import Foundation

/// Thrown by `Timeout.run` when an operation exceeds its wall-clock deadline.
public struct TimeoutError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let seconds: TimeInterval
    public init(seconds: TimeInterval) { self.seconds = seconds }
    public var description: String { "Timed out after \(Int(seconds.rounded()))s" }
    public var errorDescription: String? { description }
}

/// Runs an async operation under a wall-clock deadline.
public enum Timeout {

    /// Runs `operation`, throwing `TimeoutError` if it doesn't finish within `seconds`.
    ///
    /// Two deliberate robustness choices:
    /// 1. The deadline fires from a **Dispatch timer**, not `Task.sleep`. A Task-based
    ///    timer is scheduled on the cooperative pool, so it can be delayed when that pool
    ///    is saturated by blocking work — exactly the situation a timeout must survive.
    /// 2. The operation runs in an **unstructured** detached task that is *abandoned*
    ///    (cancelled best-effort) on timeout. We never structurally await it, so an
    ///    operation that ignores cancellation can't keep this call hanging — unlike a
    ///    task group, which awaits every child before returning.
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = RaceBox<T>()
        let work = Task.detached(priority: priority) {
            do {
                race.resolve(.success(try await operation()))
            } catch {
                race.resolve(.failure(error))
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { race.resolve(.failure(TimeoutError(seconds: seconds))) }
        timer.resume()
        defer {
            timer.cancel()
            work.cancel()  // best-effort; the abandoned task finishes harmlessly off-stage.
        }
        return try await race.value()
    }

    /// First-result-wins box bridging the detached work task and the Dispatch timer onto
    /// a single continuation. Whichever resolves first is delivered; the loser is ignored.
    private final class RaceBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var continuation: CheckedContinuation<T, Error>?

        func resolve(_ outcome: Result<T, Error>) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = outcome
            let waiter = continuation
            continuation = nil
            lock.unlock()
            waiter?.resume(with: outcome)
        }

        func value() async throws -> T {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let outcome = result {
                    lock.unlock()
                    cont.resume(with: outcome)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }
    }
}

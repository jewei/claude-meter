import Dispatch
import Foundation

/// Runs synchronous work that can block, such as a file, SQLite, or Keychain read, without
/// blocking Swift's cooperative threads.
///
/// A read can block forever, for example on a FIFO or a stuck network volume. The caller gets
/// a ``TimeoutError`` at the limit, and the abandoned work keeps its thread until it ends. A
/// process-wide cap on abandoned work stops repeated refreshes from piling up threads.
public enum BlockingIO {
    /// Too much abandoned work is still running. Try again later.
    public struct BusyError: Error, LocalizedError, Sendable {
        public var errorDescription: String? {
            "Too many earlier file reads are still waiting. Try again later."
        }
    }

    /// Lets long-running work stop early after the caller gave up.
    public struct Cancellation: Sendable {
        fileprivate let flag = Locked(false)

        public var isCancelled: Bool { flag.value }
    }

    /// The most operations that can run at once, including abandoned ones.
    public static let capacity = 16

    private static let queue = DispatchQueue(
        label: "com.jewei.claudemeter.blocking-io", qos: .utility, attributes: .concurrent)
    private static let running = Locked(0)

    public static func run<Value: Sendable>(
        timeout: Duration,
        _ work: @escaping @Sendable (Cancellation) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let admitted = running.withLock { count in
            guard count < capacity else { return false }
            count += 1
            return true
        }
        guard admitted else { throw BusyError() }

        let cancellation = Cancellation()
        let outcome = Outcome<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.install(continuation)
                queue.async {
                    let result = Result { try work(cancellation) }
                    running.withLock { $0 -= 1 }
                    outcome.finish(result)
                }
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                    cancellation.flag.withLock { $0 = true }
                    outcome.finish(.failure(TimeoutError(limit: timeout)))
                }
            }
        } onCancel: {
            cancellation.flag.withLock { $0 = true }
            outcome.finish(.failure(CancellationError()))
        }
    }

    /// Resumes a continuation once, whichever of result, timeout, or cancellation comes first.
    private final class Outcome<Value: Sendable>: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<Value, any Error>?
            var early: Result<Value, any Error>?
            var isFinished = false
        }

        private let state = Locked<State>(State())

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

extension Duration {
    /// The duration in seconds.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

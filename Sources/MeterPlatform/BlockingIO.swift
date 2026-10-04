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

    /// The most abandoned operations that may still hold threads. New work fails fast beyond
    /// this, so a stuck volume cannot exhaust the thread pool.
    public static let capacity = 16

    private static let queue = DispatchQueue(
        label: "com.jewei.claudemeter.blocking-io", qos: .utility, attributes: .concurrent)
    private static let abandoned = Locked(0)

    public static func run<Value: Sendable>(
        timeout: Duration,
        _ work: @escaping @Sendable (Cancellation) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard abandoned.value < capacity else { throw BusyError() }

        let cancellation = Cancellation()
        let outcome = Outcome<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.install(continuation)
                queue.async {
                    let result = Result { try work(cancellation) }
                    // Work that finishes after its caller gave up is no longer abandoned.
                    if !outcome.finish(result) { abandoned.withLock { $0 -= 1 } }
                }
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                    giveUp(outcome, cancellation, with: TimeoutError(limit: timeout))
                }
            }
        } onCancel: {
            giveUp(outcome, cancellation, with: CancellationError())
        }
    }

    private static func giveUp<Value>(
        _ outcome: Outcome<Value>, _ cancellation: Cancellation, with error: any Error
    ) {
        cancellation.flag.withLock { $0 = true }
        if outcome.finish(.failure(error)) { abandoned.withLock { $0 += 1 } }
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

        /// Returns true when this call decided the outcome.
        @discardableResult
        func finish(_ result: Result<Value, any Error>) -> Bool {
            let (won, continuation) = state.withLock {
                state -> (Bool, CheckedContinuation<Value, any Error>?) in
                guard !state.isFinished else { return (false, nil) }
                state.isFinished = true
                guard let continuation = state.continuation else {
                    state.early = result
                    return (true, nil)
                }
                state.continuation = nil
                return (true, continuation)
            }
            continuation?.resume(with: result)
            return won
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

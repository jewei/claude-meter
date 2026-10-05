import Dispatch
import Foundation

/// Runs synchronous work that can block, such as a file, SQLite, or Keychain read, without
/// blocking Swift's cooperative threads.
///
/// A read can block forever, for example on a FIFO or a stuck network volume. The caller gets
/// a ``TimeoutError`` at the limit, also when blocked work fills every worker thread, because
/// the timers run on their own serial queue, which always gets a thread. Work whose caller
/// gave up before the work started never runs. Work that already runs is abandoned: it keeps
/// its thread until it ends.
///
/// Each pool caps its abandoned work. While ``capacity`` abandoned operations still run, new
/// work fails at once with ``BusyError``, so a stuck volume cannot pile up threads. Work in
/// progress is not capped by the pool; the system thread pool bounds it, and the timers still
/// fire when it is full. Quota reads use ``shared`` (the static ``run(timeout:_:)``); history
/// scans use ``history``, so stuck history folders cannot make quota reads fail.
public final class BlockingIO: Sendable {
    /// Too much abandoned work is still running. Try again later.
    public struct BusyError: Error, LocalizedError, Sendable {
        public var errorDescription: String? {
            "Too many earlier reads are still waiting. Try again later."
        }
    }

    /// Lets long-running work stop early after the caller gave up.
    public struct Cancellation: Sendable {
        fileprivate let flag = Locked(false)

        public var isCancelled: Bool { flag.value }

        /// A cancellation that is already set, for tests of work that checks it.
        static var cancelled: Cancellation {
            let cancellation = Cancellation()
            cancellation.flag.withLock { $0 = true }
            return cancellation
        }
    }

    /// The pool for quota reads: credentials, auth files, databases, and the reading archive.
    public static let shared = BlockingIO(label: "quota")
    /// The pool for local history scans.
    public static let history = BlockingIO(label: "history")

    /// The most abandoned operations that may still hold threads. New work fails fast beyond
    /// this, so a stuck volume cannot exhaust the thread pool.
    public let capacity: Int

    private let queue: DispatchQueue
    private let abandoned = Locked(Abandoned())
    /// Serial queues are overcommit queues: they get a thread even when blocked work fills the
    /// pool, so a timeout always fires.
    private static let timers = DispatchQueue(
        label: "com.jewei.claudemeter.blocking-io.timers", qos: .utility)

    private struct Abandoned: Sendable {
        var count = 0
        /// Keys of work that passed its time limit and still runs, with how many operations
        /// hold each key.
        var stuckKeys: [String: Int] = [:]
    }

    /// Tests pass a serial queue to hold work back deterministically.
    init(
        label: String, capacity: Int = 16, attributes: DispatchQueue.Attributes = .concurrent
    ) {
        self.capacity = capacity
        queue = DispatchQueue(
            label: "com.jewei.claudemeter.blocking-io.\(label)", qos: .utility,
            attributes: attributes)
    }

    /// Runs `work` in the ``shared`` pool. See ``run(timeout:key:_:)``.
    public static func run<Value: Sendable>(
        timeout: Duration,
        _ work: @escaping @Sendable (Cancellation) throws -> Value
    ) async throws -> Value {
        try await shared.run(timeout: timeout, work)
    }

    /// Abandoned operations that still hold threads.
    public var abandonedCount: Int { abandoned.value.count }

    /// Whether work that was started with `key` passed its time limit and still runs. A caller
    /// can skip that resource instead of abandoning one more thread on it.
    public func isStuck(_ key: String) -> Bool {
        abandoned.value.stuckKeys[key] != nil
    }

    /// Runs `work` like ``run(timeout:key:_:)``, but a full pool is tried again up to
    /// `busyRetries` times, `retryDelay` apart, because a slow volume can still free a thread.
    /// Cancellation ends the wait.
    func run<Value: Sendable>(
        timeout: Duration, key: String, busyRetries: Int, retryDelay: Duration,
        _ work: @escaping @Sendable (Cancellation) throws -> Value
    ) async throws -> Value {
        var attempts = 0
        while true {
            do {
                return try await run(timeout: timeout, key: key, work)
            } catch is BusyError where attempts < busyRetries {
                attempts += 1
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    /// Runs `work` on a pool thread and returns its result, or throws ``TimeoutError`` after
    /// `timeout`, `CancellationError` when the task is cancelled, or ``BusyError`` at once when
    /// the pool is full.
    ///
    /// `key` names the resource that the work touches, such as a file path, for
    /// ``isStuck(_:)``.
    public func run<Value: Sendable>(
        timeout: Duration, key: String? = nil,
        _ work: @escaping @Sendable (Cancellation) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard abandoned.value.count < capacity else { throw BusyError() }

        let cancellation = Cancellation()
        let outcome = Outcome<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A caller cancelled before this point already has its error. Nothing runs.
                guard outcome.install(continuation) else { return }
                queue.async { [self] in
                    // The caller gave up before the work started: skip it.
                    let result: Result<Value, any Error> =
                        cancellation.isCancelled
                        ? .failure(CancellationError()) : Result { try work(cancellation) }
                    outcome.end(with: result, release: release)
                }
                Self.timers.asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
                    giveUp(outcome, cancellation, stuckKey: key, TimeoutError(limit: timeout))
                }
            }
        } onCancel: {
            giveUp(outcome, cancellation, stuckKey: nil, CancellationError())
        }
    }

    private func giveUp<Value>(
        _ outcome: Outcome<Value>, _ cancellation: Cancellation, stuckKey: String?,
        _ error: any Error
    ) {
        outcome.giveUp(with: error, stuckKey: stuckKey, abandon: abandon)
        // Set after the outcome, so work that sees the flag was already abandoned.
        cancellation.flag.withLock { $0 = true }
    }

    private func abandon(_ stuckKey: String?) {
        abandoned.withLock { state in
            state.count += 1
            if let stuckKey { state.stuckKeys[stuckKey, default: 0] += 1 }
        }
    }

    private func release(_ stuckKey: String?) {
        abandoned.withLock { state in
            state.count -= 1
            guard let stuckKey, let count = state.stuckKeys[stuckKey] else { return }
            state.stuckKeys[stuckKey] = count > 1 ? count - 1 : nil
        }
    }

    /// Resumes a continuation once, whichever of result, timeout, or cancellation comes first,
    /// and tracks whether the work is abandoned.
    ///
    /// The pool's counts change under this lock, so the release of abandoned work always
    /// follows its abandonment.
    private final class Outcome<Value: Sendable>: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<Value, any Error>?
            var early: Result<Value, any Error>?
            var isFinished = false
            /// Set while the work runs after its caller gave up, with its stuck key.
            var abandonment: Abandonment?
        }

        private struct Abandonment: Sendable {
            let stuckKey: String?
        }

        private let state = Locked<State>(State())

        /// Returns false when the caller gave up before it started to wait. The continuation
        /// is then resumed at once, and the work must not start.
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

        /// Ends the wait with `error`, unless the work ended first. When the work was handed
        /// to the queue, it is abandoned: `abandon` runs with `stuckKey`.
        func giveUp(
            with error: any Error, stuckKey: String?, abandon: @Sendable (String?) -> Void
        ) {
            let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
                guard !state.isFinished else { return nil }
                state.isFinished = true
                guard let continuation = state.continuation else {
                    state.early = .failure(error)
                    return nil
                }
                state.continuation = nil
                state.abandonment = Abandonment(stuckKey: stuckKey)
                abandon(stuckKey)
                return continuation
            }
            continuation?.resume(throwing: error)
        }

        /// Delivers the result of the work, or releases the work when its caller gave up.
        func end(with result: Result<Value, any Error>, release: @Sendable (String?) -> Void) {
            let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
                if let abandonment = state.abandonment {
                    state.abandonment = nil
                    release(abandonment.stuckKey)
                    return nil
                }
                guard !state.isFinished else { return nil }
                state.isFinished = true
                defer { state.continuation = nil }
                return state.continuation
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

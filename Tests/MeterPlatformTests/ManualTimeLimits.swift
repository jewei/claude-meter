import Dispatch
import Foundation
import MeterTestSupport
import Testing

@testable import MeterPlatform

/// Time limits that end only when a test says, so load on the machine cannot make a call
/// time out.
final class ManualTimeLimits: Sendable {
    private let pending = Locked<[(key: String?, expire: @Sendable () -> Void)]>([])

    var timeLimit: BlockingIO.TimeLimit {
        { [pending] _, key, expire in pending.withLock { $0.append((key, expire)) } }
    }

    /// Ends the waits of the calls whose key matches, as if their time limit passed. A call
    /// that already ended is not changed.
    func expire(where matches: (String) -> Bool) {
        let all = pending.withLock { pending in
            defer { pending = [] }
            return pending
        }
        let due = all.filter { $0.key.map(matches) ?? false }
        let rest = all.filter { !($0.key.map(matches) ?? false) }
        pending.withLock { $0 += rest }
        for call in due { call.expire() }
    }

    /// Whether a call with `key` started its time limit, which it does after it handed its
    /// work to the queue, and the test has not ended that limit yet.
    func isWaiting(_ key: String) -> Bool {
        pending.value.contains { $0.key == key }
    }

    /// Starts a read in `pool`, whose time limits these are, and ends its time limit after it
    /// started, so it is abandoned and holds its thread until the test signals the returned
    /// semaphore. A real time limit could end before the read started, and the pool would
    /// then skip the read instead of holding a thread.
    func makeStuckRead(
        in pool: BlockingIO, key: String = "stuck-\(UUID().uuidString)"
    ) async -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        let started = Locked(false)
        let read = Task {
            try await pool.run(timeout: .seconds(5), key: key) { _ in
                started.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 600)
            }
        }
        #expect(await waitUntil(limit: .seconds(60)) { started.value })
        expire { $0 == key }
        await #expect(throws: TimeoutError.self) { try await read.value }
        return release
    }
}

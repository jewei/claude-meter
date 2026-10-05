import Dispatch
import Foundation
import MeterTestSupport
import Testing

@testable import MeterPlatform

/// The time limit of a call starts before its work can start. A test that waits until the work
/// started and then ends the limit (``ManualTimeLimits``) can then never miss the limit.
extension BlockingIOTests {
    /// The time limit holds the caller after it started, longer than an idle pool takes to
    /// start work. Work that went to the queue before the limit would start during the hold.
    /// The work can never start during the hold, so the pass does not depend on time; only
    /// the detection of a wrong order does.
    @Test func theTimeLimitStartsBeforeTheWork() async throws {
        let started = DispatchSemaphore(value: 0)
        let startedDuringHold = Locked<Bool?>(nil)
        let pool = BlockingIO(label: "test") { _, _, _ in
            let result = started.wait(timeout: .now() + 0.5)
            startedDuringHold.withLock { $0 = result == .success }
        }

        let value = try await pool.run(timeout: .seconds(5)) { _ in
            started.signal()
            return 7
        }

        #expect(value == 7)
        #expect(startedDuringHold.value == false)
    }

    /// A limit that ends before the work starts abandons the work. The work then never runs,
    /// and the pool takes the abandoned work and its key back.
    @Test func aLimitThatEndsBeforeTheWorkStartsSkipsTheWork() async throws {
        let pool = BlockingIO(label: "test") { _, _, expire in expire() }
        let ran = Locked(false)

        await #expect(throws: TimeoutError.self) {
            try await pool.run(timeout: .seconds(5), key: "early") { _ in
                ran.withLock { $0 = true }
            }
        }

        #expect(
            await waitUntil(limit: .seconds(60)) {
                pool.abandonedCount == 0 && !pool.isStuck("early")
            })
        #expect(!ran.value)
    }

    /// The work is marked to skip before its caller hears of the limit. A hook in the caller's
    /// task executor (``HookedTaskExecutor``) runs on the thread that ends the limit, after the
    /// caller was resumed and before the pool's handler of the limit returns, and lets the
    /// queue reach the work there. Work that the pool started at that point would run after
    /// its caller gave up.
    @available(macOS 15, *)
    @Test func workThatReachesTheQueueAfterItsCallerHeardOfTheLimitNeverRuns() async throws {
        // A serial pool holds the call behind a blocker until the hook releases it.
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", attributes: [], timeLimit: timeLimits.timeLimit)
        let release = DispatchSemaphore(value: 0)
        let (blockerStarted, ran, hooked) = (Locked(false), Locked(false), Locked(false))
        let blocker = Task {
            try await pool.run(timeout: .seconds(5), key: "blocker") { _ in
                blockerStarted.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 600)
            }
        }
        #expect(await waitUntil(limit: .seconds(60)) { blockerStarted.value })
        let executor = HookedTaskExecutor()
        let call = Task(executorPreference: executor) {
            try await pool.run(timeout: .seconds(5), key: "call") { _ in
                ran.withLock { $0 = true }
            }
        }
        // The call's limit started, and then its task suspended.
        #expect(
            await waitUntil(limit: .seconds(60)) {
                timeLimits.isWaiting("call") && !executor.isBusy
            })

        // The hook frees the queue, then waits until the work ran or was skipped: either one
        // ends the abandonment of the call.
        executor.beforeNextJob {
            hooked.withLock { $0 = true }
            release.signal()
            let deadline = ContinuousClock.now + .seconds(60)
            while pool.abandonedCount > 0, ContinuousClock.now < deadline { usleep(1_000) }
        }
        timeLimits.expire { $0 == "call" }
        await #expect(throws: TimeoutError.self) { try await call.value }
        // Frees the blocker also when the hook did not run.
        release.signal()
        try await blocker.value

        #expect(hooked.value)
        #expect(pool.abandonedCount == 0)
        #expect(!ran.value)
    }
}

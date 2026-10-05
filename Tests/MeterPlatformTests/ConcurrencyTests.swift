import Foundation
import MeterTestSupport
import Testing

@testable import MeterPlatform

@Suite struct DeadlineTests {
    @Test func returnsTheResultInTime() async throws {
        let value = try await withDeadline(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func cancelsSlowWork() async {
        let clock = ContinuousClock()
        let start = clock.now
        let cancelled = Locked(false)
        await #expect(throws: TimeoutError(limit: .milliseconds(50))) {
            try await withDeadline(.milliseconds(50)) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.withLock { $0 = true }
                    throw error
                }
            }
        }
        #expect(clock.now - start < .seconds(5))
        #expect(await waitUntil { cancelled.value })
    }

    @Test func returnsAtTheLimitWhenTheOperationIgnoresCancellation() async {
        let gate = Gate()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: TimeoutError(limit: .milliseconds(50))) {
            try await withDeadline(.milliseconds(50)) {
                await gate.wait()
                return 1
            }
        }
        #expect(clock.now - start < .seconds(2))
        gate.open()
    }

    @Test func callerCancellationReturnsAtOnceWhenTheOperationIgnoresIt() async {
        let gate = Gate()
        let task = Task {
            try await withDeadline(.seconds(30)) {
                await gate.wait()
                return 1
            }
        }
        await gate.waitForArrivals()
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - start < .seconds(1))
        gate.open()
    }

    @Test func passesOperationErrorsThrough() async {
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await withDeadline(.seconds(5)) { () async throws -> Int in throw Failure() }
        }
    }

    @Test func aCancelledCallerStartsNothing() async {
        let started = Locked(false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withDeadline(.seconds(5)) {
                started.withLock { $0 = true }
                return 1
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!started.value)
    }

    @Test func keepsTaskLocalValues() async throws {
        let value = try await DeadlineProbe.$name.withValue("caller") {
            try await withDeadline(.seconds(5)) { DeadlineProbe.name }
        }
        #expect(value == "caller")
    }
}

private enum DeadlineProbe {
    @TaskLocal static var name = "none"
}

/// Every test that leaves blocked or abandoned work uses its own pool, so the shared pools
/// that other suites use in parallel never fill up.
///
/// No outcome depends on time. Blocked work waits until the test releases it. A pool with
/// ``ManualTimeLimits`` ends a time limit only when the test says, after the work started: a
/// real limit can end first on a loaded machine, and the pool then skips the work. The test
/// of the real timers lets its work block far longer than the test may take, and every other
/// wait has a limit far above what a loaded machine needs.
@Suite(.serialized) struct BlockingIOTests {
    @Test func returnsTheResult() async throws {
        let value = try await BlockingIO.run(timeout: .seconds(60)) { _ in "done" }
        #expect(value == "done")
    }

    @Test func manyConcurrentReadsNeverCountAsAbandoned() async throws {
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", timeLimit: timeLimits.timeLimit)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<64 {
                group.addTask {
                    try await pool.run(timeout: .seconds(5)) { _ in
                        usleep(2_000)
                        return index
                    }
                }
            }
            var total = 0
            for try await value in group { total += value }
            #expect(total == (0..<64).reduce(0, +))
        }
        #expect(pool.abandonedCount == 0)
    }

    @Test func rethrowsWorkErrors() async {
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await BlockingIO.run(timeout: .seconds(60)) { _ -> Int in throw Failure() }
        }
    }

    @Test func abandonsBlockedWorkAtTheLimit() async {
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", timeLimit: timeLimits.timeLimit)
        let release = DispatchSemaphore(value: 0)
        let (started, sawCancellation) = (Locked(false), Locked(false))
        let call = Task {
            try await pool.run(timeout: .seconds(5), key: "blocked") { cancellation in
                started.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 600)
                sawCancellation.withLock { $0 = cancellation.isCancelled }
            }
        }
        #expect(await waitUntil(limit: .seconds(60)) { started.value })
        timeLimits.expire { $0 == "blocked" }
        await #expect(throws: TimeoutError.self) { try await call.value }
        #expect(pool.abandonedCount == 1)
        release.signal()
        #expect(await waitUntil(limit: .seconds(60)) { sawCancellation.value })
        #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })
    }

    /// The call returns while its work still blocks, so it did not wait for the work.
    @Test func callerCancellationReturnsAtOnce() async {
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", timeLimit: timeLimits.timeLimit)
        let release = DispatchSemaphore(value: 0)
        let started = Locked(false)
        let task = Task {
            try await pool.run(timeout: .seconds(5)) { _ in
                started.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 600)
            }
        }
        #expect(await waitUntil(limit: .seconds(60)) { started.value })
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await withDeadline(.seconds(60)) { try await task.value }
        }
        #expect(pool.abandonedCount == 1)
        release.signal()
        #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })
    }

    /// The work blocks far longer than the test may take, so each call ends only by its real
    /// time limit, also when blocked work fills every worker thread.
    @Test func timeoutsFireWhenBlockedWorkFillsEveryThread() async {
        // More blocked calls than the system gives worker threads to a process (64).
        let pool = BlockingIO(label: "test", capacity: 100)
        let release = DispatchSemaphore(value: 0)
        let timeouts = try? await withDeadline(.seconds(60)) {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<80 {
                    group.addTask {
                        do {
                            try await pool.run(timeout: .milliseconds(100)) { _ in
                                _ = release.wait(timeout: .now() + 600)
                            }
                            return false
                        } catch {
                            return error is TimeoutError
                        }
                    }
                }
                var count = 0
                for await isTimeout in group where isTimeout { count += 1 }
                return count
            }
        }
        for _ in 0..<80 { release.signal() }
        #expect(timeouts == 80)
        // Abandoned work ends after the release, and capacity comes back.
        #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })
    }

    @Test func workWhoseCallerGaveUpBeforeItStartedNeverRuns() async throws {
        // A serial pool holds the second call behind the first.
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", attributes: [], timeLimit: timeLimits.timeLimit)
        let release = DispatchSemaphore(value: 0)
        let (firstStarted, laterRan) = (Locked(false), Locked(false))
        let first = Task {
            try await pool.run(timeout: .seconds(5), key: "first") { _ in
                firstStarted.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 600)
            }
        }
        #expect(await waitUntil(limit: .seconds(60)) { firstStarted.value })
        let later = Task {
            try await pool.run(timeout: .seconds(5), key: "later") { _ in
                laterRan.withLock { $0 = true }
            }
        }
        // The later work waits in the queue behind the first when its caller gives up.
        #expect(await waitUntil(limit: .seconds(60)) { timeLimits.isWaiting("later") })
        timeLimits.expire { $0 == "later" }
        await #expect(throws: TimeoutError.self) { try await later.value }
        timeLimits.expire { $0 == "first" }
        await #expect(throws: TimeoutError.self) { try await first.value }
        #expect(pool.abandonedCount == 2)
        release.signal()
        #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })
        #expect(!laterRan.value)
    }

    @Test func failsFastAtCapacityUntilAbandonedWorkEnds() async throws {
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", capacity: 1, timeLimit: timeLimits.timeLimit)
        let release = await timeLimits.makeStuckRead(in: pool)
        await #expect(throws: BlockingIO.BusyError.self) {
            try await pool.run(timeout: .seconds(5)) { _ in 1 }
        }
        release.signal()
        #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })
        #expect(try await pool.run(timeout: .seconds(5)) { _ in 1 } == 1)
    }

    @Test func tracksTheKeysOfWorkThatPassedItsLimit() async throws {
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", timeLimit: timeLimits.timeLimit)
        let stuck = await timeLimits.makeStuckRead(in: pool, key: "stuck")
        _ = try await pool.run(timeout: .seconds(5), key: "quick") { _ in 1 }
        // A cancelled caller proves nothing about its resource.
        let release = DispatchSemaphore(value: 0)
        let started = Locked(false)
        let cancelled = Task {
            try await pool.run(timeout: .seconds(5), key: "cancelled") { _ in
                started.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 600)
            }
        }
        #expect(await waitUntil(limit: .seconds(60)) { started.value })
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(pool.abandonedCount == 2)
        #expect(pool.isStuck("stuck"))
        #expect(!pool.isStuck("quick"))
        #expect(!pool.isStuck("cancelled"))
        stuck.signal()
        release.signal()
        #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })
        #expect(!pool.isStuck("stuck"))
    }
}

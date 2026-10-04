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
        await #expect(throws: TimeoutError(limit: .milliseconds(50))) {
            try await withDeadline(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
            }
        }
        #expect(clock.now - start < .seconds(5))
    }
}

/// Every test that leaves blocked or abandoned work uses its own pool, so the shared pools
/// that other suites use in parallel never fill up.
@Suite(.serialized) struct BlockingIOTests {
    @Test func returnsTheResult() async throws {
        let value = try await BlockingIO.run(timeout: .seconds(5)) { _ in "done" }
        #expect(value == "done")
    }

    @Test func manyConcurrentReadsNeverCountAsAbandoned() async throws {
        let pool = BlockingIO(label: "test")
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
            try await BlockingIO.run(timeout: .seconds(5)) { _ -> Int in throw Failure() }
        }
    }

    @Test func abandonsBlockedWorkAtTheLimit() async {
        let pool = BlockingIO(label: "test")
        let release = DispatchSemaphore(value: 0)
        let sawCancellation = Locked(false)
        await #expect(throws: TimeoutError.self) {
            try await pool.run(timeout: .milliseconds(50)) { cancellation in
                _ = release.wait(timeout: .now() + 5)
                sawCancellation.withLock { $0 = cancellation.isCancelled }
            }
        }
        #expect(pool.abandonedCount == 1)
        release.signal()
        #expect(await waitUntil { sawCancellation.value })
        #expect(await waitUntil { pool.abandonedCount == 0 })
    }

    @Test func callerCancellationReturnsAtOnce() async {
        let pool = BlockingIO(label: "test")
        let release = DispatchSemaphore(value: 0)
        let started = Locked(false)
        let task = Task {
            try await pool.run(timeout: .seconds(30)) { _ in
                started.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 5)
            }
        }
        #expect(await waitUntil { started.value })
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - start < .seconds(1))
        release.signal()
        #expect(await waitUntil { pool.abandonedCount == 0 })
    }

    @Test func timeoutsFireWhenBlockedWorkFillsEveryThread() async {
        // More blocked calls than the system gives worker threads to a process (64).
        let pool = BlockingIO(label: "test", capacity: 100)
        let release = DispatchSemaphore(value: 0)
        let clock = ContinuousClock()
        let start = clock.now
        let timeouts = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<80 {
                group.addTask {
                    do {
                        try await pool.run(timeout: .milliseconds(100)) { _ in
                            _ = release.wait(timeout: .now() + 5)
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
        let elapsed = clock.now - start
        for _ in 0..<80 { release.signal() }
        #expect(timeouts == 80)
        #expect(elapsed < .seconds(2))
        // Abandoned work ends after the release, and capacity comes back.
        #expect(await waitUntil { pool.abandonedCount == 0 })
    }

    @Test func workWhoseCallerGaveUpBeforeItStartedNeverRuns() async throws {
        // A serial pool holds the second call behind the first.
        let pool = BlockingIO(label: "test", attributes: [])
        let release = DispatchSemaphore(value: 0)
        let (firstStarted, laterRan) = (Locked(false), Locked(false))
        let first = Task {
            try await pool.run(timeout: .milliseconds(50)) { _ in
                firstStarted.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 5)
            }
        }
        #expect(await waitUntil { firstStarted.value })
        await #expect(throws: TimeoutError.self) {
            try await pool.run(timeout: .milliseconds(50)) { _ in laterRan.withLock { $0 = true } }
        }
        await #expect(throws: TimeoutError.self) { try await first.value }
        #expect(pool.abandonedCount == 2)
        release.signal()
        #expect(await waitUntil { pool.abandonedCount == 0 })
        #expect(!laterRan.value)
    }

    @Test func failsFastAtCapacityUntilAbandonedWorkEnds() async throws {
        let pool = BlockingIO(label: "test", capacity: 1)
        let release = DispatchSemaphore(value: 0)
        await #expect(throws: TimeoutError.self) {
            try await pool.run(timeout: .milliseconds(20)) { _ in
                _ = release.wait(timeout: .now() + 5)
            }
        }
        await #expect(throws: BlockingIO.BusyError.self) {
            try await pool.run(timeout: .seconds(5)) { _ in 1 }
        }
        release.signal()
        #expect(await waitUntil { pool.abandonedCount == 0 })
        #expect(try await pool.run(timeout: .seconds(5)) { _ in 1 } == 1)
    }

    @Test func tracksTheKeysOfWorkThatPassedItsLimit() async throws {
        let pool = BlockingIO(label: "test")
        let release = DispatchSemaphore(value: 0)
        await #expect(throws: TimeoutError.self) {
            try await pool.run(timeout: .milliseconds(20), key: "stuck") { _ in
                _ = release.wait(timeout: .now() + 5)
            }
        }
        _ = try await pool.run(timeout: .seconds(5), key: "quick") { _ in 1 }
        // A cancelled caller proves nothing about its resource.
        let started = Locked(false)
        let cancelled = Task {
            try await pool.run(timeout: .seconds(30), key: "cancelled") { _ in
                started.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 5)
            }
        }
        #expect(await waitUntil { started.value })
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(pool.abandonedCount == 2)
        #expect(pool.isStuck("stuck"))
        #expect(!pool.isStuck("quick"))
        #expect(!pool.isStuck("cancelled"))
        release.signal()
        release.signal()
        #expect(await waitUntil { pool.abandonedCount == 0 })
        #expect(!pool.isStuck("stuck"))
    }
}

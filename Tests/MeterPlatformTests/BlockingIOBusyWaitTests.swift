import Foundation
import MeterTestSupport
import Testing

@testable import MeterPlatform

/// The wait of a call that finds the pool full. Each test fills a pool of one thread with a
/// stuck read. No step depends on time: the stuck read ends only when the test releases it,
/// and each wait between tries is a gate that the test opens, or a pause that it cancels.
extension BlockingIOTests {
    @Test func aThreadThatBecomesFreeDuringTheWaitRunsTheWork() async throws {
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", capacity: 1, timeLimit: timeLimits.timeLimit)
        let release = await timeLimits.makeStuckRead(in: pool)
        let gate = Gate()
        let wait = BlockingIO.BusyWait(retries: 3) { await gate.wait() }
        let call = Task {
            try await pool.run(timeout: .seconds(5), key: "next", busyWait: wait) { _ in 7 }
        }

        // The first try finds the pool full and waits. The stuck read ends during the wait.
        #expect(await gate.waitForArrivals(1, limit: .seconds(60)))
        release.signal()
        #expect(await waitUntil(limit: .seconds(60)) { pool.abandonedCount == 0 })
        gate.open()
        #expect(try await call.value == 7)
        #expect(gate.arrivals == 1)
    }

    @Test func cancellationEndsTheWait() async throws {
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", capacity: 1, timeLimit: timeLimits.timeLimit)
        let release = await timeLimits.makeStuckRead(in: pool)
        defer { release.signal() }
        // The wait of the app, with a pause so long that only cancellation can end it.
        let standard = BlockingIO.BusyWait.retries(1_000, every: .seconds(600))
        let pauses = Locked(0)
        let wait = BlockingIO.BusyWait(retries: standard.retries) {
            pauses.withLock { $0 += 1 }
            try await standard.pause()
        }
        let call = Task {
            try await pool.run(timeout: .seconds(5), key: "next", busyWait: wait) { _ in 7 }
        }

        #expect(await waitUntil(limit: .seconds(60)) { pauses.value == 1 })
        call.cancel()
        await #expect(throws: CancellationError.self) {
            try await withDeadline(.seconds(60)) { try await call.value }
        }
        #expect(pauses.value == 1)
        #expect(pool.abandonedCount == 1)
    }

    @Test func aPoolThatStaysFullFailsAfterTheLastTry() async throws {
        let timeLimits = ManualTimeLimits()
        let pool = BlockingIO(label: "test", capacity: 1, timeLimit: timeLimits.timeLimit)
        let release = await timeLimits.makeStuckRead(in: pool)
        defer { release.signal() }
        let pauses = Locked(0)
        let wait = BlockingIO.BusyWait(retries: 2) { pauses.withLock { $0 += 1 } }
        let ran = Locked(false)
        await #expect(throws: BlockingIO.BusyError.self) {
            try await pool.run(timeout: .seconds(5), key: "next", busyWait: wait) { _ in
                ran.withLock { $0 = true }
            }
        }
        #expect(pauses.value == 2)
        #expect(!ran.value)
    }
}

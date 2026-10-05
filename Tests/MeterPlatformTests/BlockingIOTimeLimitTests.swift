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
}

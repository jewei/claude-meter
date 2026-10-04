import Foundation
import MeterPlatform
import Testing

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

@Suite struct BlockingIOTests {
    @Test func returnsTheResult() async throws {
        let value = try await BlockingIO.run(timeout: .seconds(5)) { _ in "done" }
        #expect(value == "done")
    }

    @Test func manyConcurrentReadsNeverCountAsAbandoned() async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<64 {
                group.addTask {
                    try await BlockingIO.run(timeout: .seconds(5)) { _ in
                        usleep(2_000)
                        return index
                    }
                }
            }
            var total = 0
            for try await value in group { total += value }
            #expect(total == (0..<64).reduce(0, +))
        }
    }

    @Test func rethrowsWorkErrors() async {
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await BlockingIO.run(timeout: .seconds(5)) { _ -> Int in throw Failure() }
        }
    }

    @Test func abandonsBlockedWorkAtTheLimit() async {
        let release = DispatchSemaphore(value: 0)
        let sawCancellation = Locked(false)
        await #expect(throws: TimeoutError.self) {
            try await BlockingIO.run(timeout: .milliseconds(50)) { cancellation in
                _ = release.wait(timeout: .now() + 5)
                sawCancellation.withLock { $0 = cancellation.isCancelled }
            }
        }
        release.signal()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sawCancellation.value)
    }

    @Test func callerCancellationReturnsAtOnce() async {
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await BlockingIO.run(timeout: .seconds(30)) { _ in
                _ = release.wait(timeout: .now() + 5)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        release.signal()
    }
}

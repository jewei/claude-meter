import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("Timeout")
struct TimeoutTests {

    @Test("Returns the operation's value when it finishes in time")
    func fastOperationReturns() async throws {
        let value = try await Timeout.run(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test("Throws TimeoutError when the operation exceeds the deadline")
    func slowOperationTimesOut() async {
        do {
            _ = try await Timeout.run(seconds: 0.1) {
                // Far longer than the deadline; abandoned on timeout.
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            Issue.record("expected a TimeoutError")
        } catch is TimeoutError {
            // expected
        } catch {
            Issue.record("expected TimeoutError, got \(error)")
        }
    }

    @Test("Propagates the operation's own error instead of timing out")
    func operationErrorPropagates() async {
        struct Boom: Error {}
        do {
            _ = try await Timeout.run(seconds: 5) { () throws -> Int in throw Boom() }
            Issue.record("expected Boom")
        } catch is Boom {
            // expected
        } catch {
            Issue.record("expected Boom, got \(error)")
        }
    }

    @Test("Timeout fires on wall-clock time, roughly when expected")
    func timeoutIsWallClockBounded() async {
        let start = Date()
        _ = try? await Timeout.run(seconds: 0.2) {
            try await Task.sleep(for: .seconds(30))
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5)  // returns promptly at the deadline, not after the 30s sleep
    }

    @Test("Rejects invalid timeout durations before scheduling")
    func invalidDurations() async {
        for seconds in [0.0, -1.0, .infinity, .nan] {
            await #expect(throws: InvalidTimeoutDurationError.self) {
                try await Timeout.run(seconds: seconds) { 1 }
            }
        }
    }

    @Test("Caller cancellation returns without waiting for the deadline")
    func callerCancellationReturnsPromptly() async {
        let task = Task {
            try await Timeout.run(seconds: 30) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        await Task.yield()
        let startedAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test("An isolated budget cannot exhaust the default timeout pool")
    func isolatedBudgetDoesNotAffectDefaultPool() async throws {
        let budget = Timeout.TaskBudget(limit: 1)
        let blocker = DispatchSemaphore(value: 0)
        let first = Task {
            try await Timeout.run(seconds: 0.05, budget: budget) {
                waitIgnoringCancellation(blocker)
                return 1
            }
        }
        defer {
            blocker.signal()
            first.cancel()
        }

        await #expect(throws: TimeoutError.self) { try await first.value }
        await #expect(throws: TimeoutCapacityError.self) {
            try await Timeout.run(seconds: 1, budget: budget) { 2 }
        }
        #expect(try await Timeout.run(seconds: 1) { 3 } == 3)
    }
}

/// Deliberately blocks the detached worker to model a filesystem call that does
/// not observe Swift task cancellation.
private func waitIgnoringCancellation(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

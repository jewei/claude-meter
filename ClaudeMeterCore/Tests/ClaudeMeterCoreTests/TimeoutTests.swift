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
}

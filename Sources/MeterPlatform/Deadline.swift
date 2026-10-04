import Foundation

/// Work did not finish within its time limit.
public struct TimeoutError: Error, LocalizedError, Equatable, Sendable {
    public let limit: Duration

    public init(limit: Duration) {
        self.limit = limit
    }

    public var errorDescription: String? {
        "Timed out after \(limit.formatted(.units(allowed: [.seconds], width: .narrow)))."
    }
}

/// Runs `operation` and cancels it when `limit` passes.
///
/// The operation must respond to cancellation, as URLSession and `Task.sleep` do. Wrap
/// blocking calls, such as file or Keychain reads, in ``BlockingIO/run(timeout:_:)`` instead.
public func withDeadline<Value: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimeoutError(limit: limit)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

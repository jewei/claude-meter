import os

/// A value protected by an unfair lock. Use it for small state that synchronous code shares
/// across threads. Prefer an actor when the state is touched from async code only.
public final class Locked<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ value: Value) {
        lock = OSAllocatedUnfairLock(initialState: value)
    }

    public var value: Value {
        lock.withLock { $0 }
    }

    @discardableResult
    public func withLock<Result: Sendable>(_ body: @Sendable (inout Value) -> Result) -> Result {
        lock.withLock(body)
    }
}

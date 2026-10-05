import MeterPlatform

/// Suspends callers until a test opens it. Use it to hold a fake provider mid-request.
public final class Gate: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var arrivals = 0
    }

    private let state = Locked(State())

    public init() {}

    /// How many callers reached ``wait()``.
    public var arrivals: Int { state.value.arrivals }

    public func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                state.arrivals += 1
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    public func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Waits until `count` callers reached the gate. Returns false after `limit`.
    @discardableResult
    public func waitForArrivals(_ count: Int = 1, limit: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while arrivals < count {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

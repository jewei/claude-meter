import Foundation

/// Lets one scan run at a time, in arrival order.
///
/// A scan suspends while it waits for blocking reads, and an actor would let a second scan
/// change the shared cursors meanwhile. A waiting scan leaves the queue at once when its task
/// is cancelled, so the caller's deadline still holds.
actor ScanQueue {
    private var isBusy = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID: UInt64 = 0

    /// Scans that wait for their turn. Tests use it to wait without sleeping.
    var waitingCount: Int { waiters.count }

    /// Returns when the caller may scan. Throws `CancellationError` when the task is cancelled
    /// while it waits. Every successful call needs one ``leave()``.
    func enter() async throws {
        try Task.checkCancellation()
        guard isBusy else {
            isBusy = true
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                wait(id, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Gives the turn to the next waiting scan.
    func leave() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    private func wait(_ id: UInt64, _ continuation: CheckedContinuation<Void, any Error>) {
        // The cancellation handler can run before the waiter is stored; it then finds nothing.
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            waiters.append((id, continuation))
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

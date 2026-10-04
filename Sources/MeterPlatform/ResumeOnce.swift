/// Resumes a continuation at most once, whichever caller comes first.
final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Locked<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Locked(continuation)
    }

    func resume(_ value: Value) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}

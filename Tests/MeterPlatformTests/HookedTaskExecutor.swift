import Dispatch
import MeterPlatform

/// A task executor that can run a hook on the thread that queues the next job of a task that
/// prefers it, before the job is queued.
///
/// A continuation that resumes a suspended task queues the task's next job at once, on the
/// thread that resumes it. So the hook runs after the waiting caller was resumed, and before
/// the code that resumed it goes on: a test can act between those two steps.
@available(macOS 15, *)
final class HookedTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "com.jewei.claudemeter.tests.hooked-executor")
    private let hook = Locked<(@Sendable () -> Void)?>(nil)
    private let jobs = Locked(0)

    /// Whether a job of a task that prefers this executor is queued or runs. False after the
    /// task suspended, until something resumes it.
    var isBusy: Bool { jobs.value > 0 }

    /// Runs `action` once, on the thread that queues the next job, before the job is queued.
    func beforeNextJob(_ action: @escaping @Sendable () -> Void) {
        hook.withLock { $0 = action }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let action = hook.withLock { hook in
            defer { hook = nil }
            return hook
        }
        action?()
        let job = UnownedJob(job)
        jobs.withLock { $0 += 1 }
        queue.async { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
            jobs.withLock { $0 -= 1 }
        }
    }
}

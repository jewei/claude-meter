import Darwin
import Foundation

/// A short-lived child process that exchanges newline-delimited messages on stdin and stdout.
///
/// After ``start()`` succeeds, every exit path must call ``stop()``, which sends SIGTERM, waits
/// a short grace period, sends SIGKILL if needed, and waits a bounded time for the reap.
/// ``stop()`` returns at once for a process that never launched. A write never blocks and
/// never raises SIGPIPE: it throws when the child does not read. Lines and the unread backlog
/// are bounded, and a truncated line is never delivered.
///
/// `@unchecked Sendable`: `state` is guarded by its lock, and `lines` is a thread-safe stream.
/// `process`, `input`, and `output` are used only by the one task that owns this object
/// (`start`, `send`, `stop`); Foundation's handlers touch only `state` and the stream.
public final class LineProcess: @unchecked Sendable {
    public enum ProcessError: Error, Equatable, LocalizedError, Sendable {
        case launchFailed(String)
        case notRunning
        /// The child does not read its input, and the pipe is full.
        case inputBlocked
        case lineTooLong(limit: Int)
        case backlogTooLarge(limit: Int)

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let reason): "The process could not start: \(reason)"
            case .notRunning: "The process is not running."
            case .inputBlocked: "The process stopped reading its input."
            case .lineTooLong(let limit): "The process wrote a line longer than \(limit) bytes."
            case .backlogTooLarge(let limit): "The process wrote more than \(limit) unread bytes."
            }
        }
    }

    public static let terminationGrace: Duration = .milliseconds(250)
    /// How long ``stop()`` waits for the reap after the last signal. A child in uninterruptible
    /// I/O, such as a read from a hung network volume, can outlive SIGKILL for a long time.
    public static let reapLimit: Duration = .seconds(2)
    private static let log = Log(.app)
    /// A serial queue gets a thread even when blocked work fills the global pool, so the
    /// grace period and the reap limit always end.
    private static let timers = DispatchQueue(
        label: "com.jewei.claudemeter.line-process.timers", qos: .utility)

    /// Complete stdout lines, without the newline. Finishes when stdout closes.
    public let lines: AsyncThrowingStream<Data, any Error>

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let maxLineBytes: Int
    private let maxBacklogBytes: Int
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let state = Locked(State())

    private struct State: Sendable {
        var buffer = Data()
        var backlogBytes = 0
        var hasLaunched = false
        var isInputClosed = false
        var hasExited = false
        var exitWaiters: [ResumeOnce<Bool>] = []
    }

    public init(
        executable: URL, arguments: [String], environment: [String: String],
        maxLineBytes: Int = 1024 * 1024, maxBacklogBytes: Int = 8 * 1024 * 1024
    ) {
        self.maxLineBytes = maxLineBytes
        self.maxBacklogBytes = maxBacklogBytes
        (lines, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    public func start() throws {
        let stdin = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(stdin, F_SETNOSIGPIPE, 1)
        // A child that stops reading must not block the caller's thread.
        _ = fcntl(stdin, F_SETFL, fcntl(stdin, F_GETFL) | O_NONBLOCK)
        // Install handlers before launch, so a fast exit cannot be missed.
        process.terminationHandler = { [weak self] _ in self?.didExit() }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            continuation.finish(throwing: ProcessError.launchFailed(error.localizedDescription))
            throw ProcessError.launchFailed(error.localizedDescription)
        }
        state.withLock { $0.hasLaunched = true }
    }

    /// Writes `line` and a newline to stdin without blocking.
    ///
    /// Throws ``ProcessError/inputBlocked`` when the pipe is full because the child does not
    /// read. Part of the line can then be written already, so stop the process.
    public func send(_ line: Data) throws {
        let isOpen = state.withLock { $0.hasLaunched && !$0.isInputClosed }
        guard isOpen, process.isRunning else { throw ProcessError.notRunning }
        let descriptor = input.fileHandleForWriting.fileDescriptor
        try (line + Data([0x0A])).withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                    continue
                }
                switch errno {
                case EINTR: continue
                case EAGAIN: throw ProcessError.inputBlocked
                // EPIPE: the child closed its input or exited.
                default: throw ProcessError.notRunning
                }
            }
        }
    }

    /// Call after reading a line from ``lines``, so the backlog limit counts unread data only.
    public func didConsume(_ line: Data) {
        state.withLock { $0.backlogBytes = max(0, $0.backlogBytes - line.count) }
    }

    /// Stops the process and waits until it is reaped, at most ``reapLimit`` after the last
    /// signal. Returns at once when the process never launched. Safe to call more than once.
    public func stop() async {
        let (hasLaunched, closesInput) = state.withLock { state in
            defer { state.isInputClosed = true }
            return (state.hasLaunched, !state.isInputClosed)
        }
        if closesInput { try? input.fileHandleForWriting.close() }
        // A process that never launched has no exit to wait for.
        guard hasLaunched else { return }
        if process.isRunning {
            process.terminate()
            let exited = await waitForExit(timeout: Self.terminationGrace)
            if !exited, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        if await !waitForExit(timeout: Self.reapLimit) {
            Self.log.error(
                "A child process was not reaped \(Self.reapLimit) after it was stopped. "
                    + "It is left running.")
        }
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else {
            output.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            return
        }
        let result = state.withLock { state -> Result<[Data], ProcessError> in
            state.buffer.append(chunk)
            var lines: [Data] = []
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                let line = state.buffer[state.buffer.startIndex..<newline]
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
                guard line.count <= maxLineBytes else {
                    return .failure(.lineTooLong(limit: maxLineBytes))
                }
                state.backlogBytes += line.count
                lines.append(Data(line))
            }
            if state.buffer.count > maxLineBytes {
                return .failure(.lineTooLong(limit: maxLineBytes))
            }
            if state.backlogBytes > maxBacklogBytes {
                return .failure(.backlogTooLarge(limit: maxBacklogBytes))
            }
            return .success(lines)
        }
        switch result {
        case .success(let lines):
            for line in lines { continuation.yield(line) }
        case .failure(let error):
            output.fileHandleForReading.readabilityHandler = nil
            continuation.finish(throwing: error)
        }
    }

    private func didExit() {
        let waiters = state.withLock { state in
            state.hasExited = true
            defer { state.exitWaiters = [] }
            return state.exitWaiters
        }
        for waiter in waiters { waiter.resume(true) }
    }

    /// Returns true when the process exited within `timeout`.
    private func waitForExit(timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiter = ResumeOnce(continuation)
            let hasExited = state.withLock { state in
                if !state.hasExited { state.exitWaiters.append(waiter) }
                return state.hasExited
            }
            if hasExited {
                waiter.resume(true)
            } else {
                Self.timers.asyncAfter(deadline: .now() + timeout.timeInterval) {
                    waiter.resume(false)
                }
            }
        }
    }
}

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

import Darwin
import Foundation
import MeterDomain

/// A short-lived child process that exchanges newline-delimited messages on stdin and stdout.
///
/// After ``start()`` succeeds, every exit path must call ``stop()``, which sends SIGTERM to the
/// child's process group, waits a short grace period, sends SIGKILL, and waits a bounded time
/// for the reap. ``stop()`` returns at once for a process that never launched. A write never
/// blocks and never raises SIGPIPE: it throws when the child does not read. Lines and the
/// unread backlog are bounded, and a truncated line is never delivered. The last 2 KiB of
/// stderr are kept for ``lastErrorLine``.
///
/// `@unchecked Sendable`: `state` is guarded by its lock, `lines` is a thread-safe stream, and
/// stderr reads run on the serial queue `errorReads`. `process` is used only by the one task
/// that owns this object (`start`, `send`, `stop`). Foundation's handlers read the pipes'
/// descriptors, touch `state` and the stream, and clear their own `readabilityHandler`;
/// `FileHandle` is `Sendable` and that property is atomic, so `stop()` may clear it at the same
/// time.
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
    /// The stderr bytes kept for ``lastErrorLine``.
    public static let errorTailBytes = 2 * 1024
    private static let log = Log(.app)
    /// A serial queue gets a thread even when blocked work fills the global pool, so the
    /// grace period and the reap limit always end.
    private static let timers = DispatchQueue(
        label: "com.jewei.claudemeter.line-process.timers", qos: .utility)

    /// Complete stdout lines, without the newline. Finishes when stdout closes or at ``stop()``.
    public let lines: AsyncThrowingStream<Data, any Error>

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let maxLineBytes: Int
    private let maxBacklogBytes: Int
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let state = Locked(State())
    /// Keeps stderr bytes in order when a handler and ``stop()`` read at the same time, without
    /// holding the lock of `state` during `read(2)`.
    private let errorReads = DispatchQueue(label: "com.jewei.claudemeter.line-process.stderr")

    private struct State: Sendable {
        var buffer = Data()
        var backlogBytes = 0
        var errorTail = Data()
        var hasLaunched = false
        /// The child leads its own process group, so signals can reach its children too.
        var leadsGroup = false
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
        process.standardError = errors
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    /// The last non-empty line that the child wrote to stderr, redacted, or nil. Read it after
    /// ``stop()`` for everything that the child wrote before it ended.
    public var lastErrorLine: String? {
        let text = String(decoding: state.value.errorTail, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return line.map(Redactor.redact)
    }

    public func start() throws {
        let stdin = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(stdin, F_SETNOSIGPIPE, 1)
        // Neither a child that stops reading nor an empty pipe may block a thread.
        let (stdout, stderr) = (
            output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor
        )
        for descriptor in [stdin, stdout, stderr] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        // Install handlers before launch, so a fast exit cannot be missed. They read with
        // read(2): `availableData` raises an Objective-C exception on a read error.
        process.terminationHandler = { [weak self] _ in self?.didExit() }
        output.fileHandleForReading.readabilityHandler = { [weak self] _ in
            self?.readOutput(stdout)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] _ in
            self?.readErrors(stderr)
        }
        do {
            try process.run()
        } catch {
            removeHandlers()
            continuation.finish(throwing: ProcessError.launchFailed(error.localizedDescription))
            throw ProcessError.launchFailed(error.localizedDescription)
        }
        // Foundation starts the child as the leader of a new process group.
        let pid = process.processIdentifier
        let leadsGroup = getpgid(pid) == pid
        state.withLock {
            $0.hasLaunched = true
            $0.leadsGroup = leadsGroup
        }
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

    /// Stops the process group and waits until the child is reaped, at most ``reapLimit``
    /// after the last signal. Then it reads the rest of stderr, stops reading, and finishes
    /// ``lines``. Returns at once when the process never launched. Safe to call more than once.
    ///
    /// The group is signaled also when the child already exited, because a background child of
    /// the child can still run in it.
    public func stop() async {
        let (hasLaunched, leadsGroup, closesInput) = state.withLock { state in
            defer { state.isInputClosed = true }
            return (state.hasLaunched, state.leadsGroup, !state.isInputClosed)
        }
        if closesInput { try? input.fileHandleForWriting.close() }
        // A process that never launched has no exit to wait for.
        guard hasLaunched else { return }
        if process.isRunning || leadsGroup {
            // An empty group fails with ESRCH, which is harmless.
            signal(SIGTERM)
            let exited = await waitForExit(timeout: Self.terminationGrace)
            // The group can outlive the child, so it gets SIGKILL too.
            if !exited || leadsGroup { signal(SIGKILL) }
        }
        if await !waitForExit(timeout: Self.reapLimit) {
            Self.log.error(
                "A child process was not reaped \(Self.reapLimit) after it was stopped. "
                    + "It is left running.")
        }
        removeHandlers()
        readErrors(errors.fileHandleForReading.fileDescriptor)
        continuation.finish()
    }

    /// Signals the child's process group when the child leads one, otherwise the child.
    private func signal(_ signal: Int32) {
        let pid = process.processIdentifier
        if state.value.leadsGroup {
            killpg(pid, signal)
        } else {
            kill(pid, signal)
        }
    }

    private func removeHandlers() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }

    private func readOutput(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 {
            receive(Data(buffer[0..<count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // End of file, or a read error that the next call would repeat.
            output.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
        }
    }

    /// Reads everything that stderr holds now and keeps the last ``errorTailBytes``. Reads run
    /// on `errorReads`, so the bytes stay in order when ``stop()`` reads too, and only the
    /// append takes the lock of `state`.
    private func readErrors(_ descriptor: Int32) {
        let limit = Self.errorTailBytes
        let isAtEnd = errorReads.sync { () -> Bool in
            var buffer = [UInt8](repeating: 0, count: 4 * 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    let bytes = Data(buffer[0..<count])
                    state.withLock { state in
                        state.errorTail.append(bytes)
                        if state.errorTail.count > limit {
                            state.errorTail = Data(state.errorTail.suffix(limit))
                        }
                    }
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return count == 0 || errno != EAGAIN
                }
            }
        }
        if isAtEnd { errors.fileHandleForReading.readabilityHandler = nil }
    }

    private func receive(_ chunk: Data) {
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

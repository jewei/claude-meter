import Darwin
import Foundation

/// A short-lived child process that exchanges newline-delimited messages on stdin and stdout.
///
/// Every exit path must call ``stop()``, which sends SIGTERM, waits a short grace period,
/// sends SIGKILL if needed, and returns only after the process is reaped. A write to a closed
/// pipe throws instead of raising SIGPIPE. Lines and the unread backlog are bounded, and a
/// truncated line is never delivered.
public final class LineProcess: @unchecked Sendable {
    public enum ProcessError: Error, Equatable, LocalizedError, Sendable {
        case launchFailed(String)
        case notRunning
        case lineTooLong(limit: Int)
        case backlogTooLarge(limit: Int)

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let reason): "The process could not start: \(reason)"
            case .notRunning: "The process is not running."
            case .lineTooLong(let limit): "The process wrote a line longer than \(limit) bytes."
            case .backlogTooLarge(let limit): "The process wrote more than \(limit) unread bytes."
            }
        }
    }

    public static let terminationGrace: Duration = .milliseconds(250)

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
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
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
    }

    /// Writes `line` and a newline to stdin.
    public func send(_ line: Data) throws {
        guard process.isRunning else { throw ProcessError.notRunning }
        try input.fileHandleForWriting.write(contentsOf: line + Data([0x0A]))
    }

    /// Call after reading a line from ``lines``, so the backlog limit counts unread data only.
    public func didConsume(_ line: Data) {
        state.withLock { $0.backlogBytes = max(0, $0.backlogBytes - line.count) }
    }

    /// Stops the process and waits until it is reaped. Safe to call more than once.
    public func stop() async {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let exited = await waitForExit(timeout: Self.terminationGrace)
            if !exited, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        _ = await waitForExit(timeout: nil)
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

    /// Returns true when the process exited within `timeout` (nil waits without limit).
    private func waitForExit(timeout: Duration?) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiter = ResumeOnce(continuation)
            let hasExited = state.withLock { state in
                if !state.hasExited { state.exitWaiters.append(waiter) }
                return state.hasExited
            }
            if hasExited {
                waiter.resume(true)
            } else if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
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

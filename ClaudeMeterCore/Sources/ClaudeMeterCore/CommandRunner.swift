@preconcurrency import Foundation
import os

// MARK: - Output + Errors

public struct CommandOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let durationSeconds: Double

    public var succeeded: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32, durationSeconds: Double) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
    }
}

public enum CommandError: Error, Sendable, Equatable {
    case cliNotFound(path: String)
    case timeout(seconds: Double)
    case launchFailed(message: String)
}

// MARK: - Protocol

public protocol ClaudeCommandRunner: Sendable {
    func fetchStatus() async throws -> CommandOutput
    /// Returns nil when stats command is not configured.
    func fetchStats() async throws -> CommandOutput?
}

// MARK: - Configuration

public struct RunnerConfig: Sendable, Equatable {
    public var cliPath: String
    public var statusSubcommand: String
    public var statsSubcommand: String?
    public var timeoutSeconds: Double
    public var extraEnvironment: [String: String]

    public init(
        cliPath: String,
        statusSubcommand: String = "status",
        statsSubcommand: String? = "stats",
        timeoutSeconds: Double = 5,
        extraEnvironment: [String: String] = [:]
    ) {
        self.cliPath = cliPath
        self.statusSubcommand = statusSubcommand
        self.statsSubcommand = statsSubcommand
        self.timeoutSeconds = timeoutSeconds
        self.extraEnvironment = extraEnvironment
    }
}

// MARK: - Concrete implementation

public struct ProcessCommandRunner: ClaudeCommandRunner {
    public let config: RunnerConfig

    /// PATH handed to every subprocess. Does not inherit the user's shell environment.
    private static let basePATH =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public init(config: RunnerConfig) {
        self.config = config
    }

    public func fetchStatus() async throws -> CommandOutput {
        guard FileManager.default.isExecutableFile(atPath: config.cliPath) else {
            throw CommandError.cliNotFound(path: config.cliPath)
        }
        return try await run(subcommand: config.statusSubcommand)
    }

    public func fetchStats() async throws -> CommandOutput? {
        guard let sub = config.statsSubcommand else { return nil }
        guard FileManager.default.isExecutableFile(atPath: config.cliPath) else {
            throw CommandError.cliNotFound(path: config.cliPath)
        }
        return try await run(subcommand: sub)
    }

    // MARK: - Process execution

    private func run(subcommand: String) async throws -> CommandOutput {
        let cliPath = config.cliPath
        let timeoutSeconds = config.timeoutSeconds
        let environment = buildEnvironment()

        // Use a continuation + DispatchQueue so the blocking waitUntilExit() never
        // occupies a Swift cooperative thread. The DispatchSource timer and the
        // terminationHandler both dispatch back to the same serial queue, making
        // the `didResume` flag safe without additional locking.
        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "com.claudemeter.process.\(UUID().uuidString)", qos: .userInitiated)

            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let start = Date()

            // OSAllocatedUnfairLock makes the read-then-set atomic across the timer
            // handler and the terminationHandler, which may run on different threads.
            let didResume = OSAllocatedUnfairLock(initialState: false)

            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = [subcommand]
            process.environment = environment
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler {
                let first = didResume.withLock { state -> Bool in
                    defer { state = true }
                    return !state
                }
                guard first else { return }
                process.terminate()
                continuation.resume(throwing: CommandError.timeout(seconds: timeoutSeconds))
            }
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.resume()

            process.terminationHandler = { p in
                queue.async {
                    timer.cancel()
                    let first = didResume.withLock { state -> Bool in
                        defer { state = true }
                        return !state
                    }
                    guard first else { return }

                    let stdout = readPipe(stdoutPipe)
                    let stderr = readPipe(stderrPipe)
                    continuation.resume(returning: CommandOutput(
                        stdout: stdout,
                        stderr: stderr,
                        exitCode: p.terminationStatus,
                        durationSeconds: Date().timeIntervalSince(start)
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                queue.async {
                    timer.cancel()
                    let first = didResume.withLock { state -> Bool in
                        defer { state = true }
                        return !state
                    }
                    guard first else { return }
                    continuation.resume(throwing: CommandError.launchFailed(message: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Helpers

    private func buildEnvironment() -> [String: String] {
        var env = ["PATH": Self.basePATH, "HOME": ProcessInfo.processInfo.environment["HOME"] ?? ""]
        for (k, v) in config.extraEnvironment { env[k] = v }
        return env
    }
}

private func readPipe(_ pipe: Pipe) -> String {
    String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

// MARK: - Mock (for tests and previews)

public struct MockCommandRunner: ClaudeCommandRunner {
    public let statusOutput: String
    public let statsOutput: String?
    public let statusError: (any Error & Sendable)?

    public init(
        statusOutput: String = "",
        statsOutput: String? = nil,
        statusError: (any Error & Sendable)? = nil
    ) {
        self.statusOutput = statusOutput
        self.statsOutput = statsOutput
        self.statusError = statusError
    }

    public func fetchStatus() async throws -> CommandOutput {
        if let error = statusError { throw error }
        return CommandOutput(stdout: statusOutput, stderr: "", exitCode: 0, durationSeconds: 0.01)
    }

    public func fetchStats() async throws -> CommandOutput? {
        statsOutput.map { CommandOutput(stdout: $0, stderr: "", exitCode: 0, durationSeconds: 0.01) }
    }
}

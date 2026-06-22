import Testing
import Foundation
@testable import ClaudeMeterCore

// These tests execute real macOS processes. All binaries used (/bin/echo, /bin/cat,
// /bin/sleep, /usr/bin/false) are part of macOS base and always present.

private func echoRunner(timeout: Double = 5) -> ProcessCommandRunner {
    // Point statusSubcommand at /bin/echo with the arg "hello" by using a wrapper trick:
    // We configure the runner to run "/bin/echo" as if it were the CLI, and pass
    // "hello" as the subcommand (the only argument).
    ProcessCommandRunner(config: RunnerConfig(
        cliPath: "/bin/echo",
        statusSubcommand: "hello",
        statsSubcommand: nil,
        timeoutSeconds: timeout
    ))
}

@Suite("ProcessCommandRunner")
struct CommandRunnerTests {

    @Test("Captures stdout from a successful process")
    func capturesStdout() async throws {
        let output = try await echoRunner().fetchStatus()
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(output.stderr.isEmpty)
        #expect(output.exitCode == 0)
        #expect(output.succeeded)
        #expect(output.durationSeconds > 0)
    }

    @Test("Captures non-zero exit code")
    func nonZeroExit() async throws {
        let runner = ProcessCommandRunner(config: RunnerConfig(
            cliPath: "/usr/bin/false",
            statusSubcommand: "",
            statsSubcommand: nil,
            timeoutSeconds: 5
        ))
        let output = try await runner.fetchStatus()
        #expect(output.exitCode != 0)
        #expect(!output.succeeded)
    }

    @Test("Captures empty stdout")
    func emptyOutput() async throws {
        let runner = ProcessCommandRunner(config: RunnerConfig(
            cliPath: "/bin/echo",
            statusSubcommand: "",
            statsSubcommand: nil,
            timeoutSeconds: 5
        ))
        let output = try await runner.fetchStatus()
        // echo with empty arg prints a newline only
        #expect(output.stdout.trimmingCharacters(in: .newlines).isEmpty)
        #expect(output.exitCode == 0)
    }

    @Test("Throws cliNotFound for missing binary")
    func cliNotFound() async throws {
        let runner = ProcessCommandRunner(config: RunnerConfig(
            cliPath: "/does/not/exist/claude",
            statusSubcommand: "status",
            timeoutSeconds: 5
        ))
        await #expect(throws: CommandError.cliNotFound(path: "/does/not/exist/claude")) {
            try await runner.fetchStatus()
        }
    }

    @Test("Throws timeout when process exceeds limit")
    func timeoutFires() async throws {
        let runner = ProcessCommandRunner(config: RunnerConfig(
            cliPath: "/bin/sleep",
            statusSubcommand: "10",
            statsSubcommand: nil,
            timeoutSeconds: 0.3
        ))
        do {
            _ = try await runner.fetchStatus()
            Issue.record("Expected timeout error")
        } catch CommandError.timeout {
            // expected
        }
    }

    @Test("fetchStats returns nil when statsSubcommand is nil")
    func statsNilWhenNotConfigured() async throws {
        let runner = ProcessCommandRunner(config: RunnerConfig(
            cliPath: "/bin/echo",
            statusSubcommand: "hello",
            statsSubcommand: nil,
            timeoutSeconds: 5
        ))
        let result = try await runner.fetchStats()
        #expect(result == nil)
    }

    @Test("fetchStats executes when statsSubcommand is set")
    func statsFetches() async throws {
        let runner = ProcessCommandRunner(config: RunnerConfig(
            cliPath: "/bin/echo",
            statusSubcommand: "hello",
            statsSubcommand: "world",
            timeoutSeconds: 5
        ))
        let result = try await runner.fetchStats()
        #expect(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "world")
    }
}

// MARK: - Mock runner

@Suite("MockCommandRunner")
struct MockCommandRunnerTests {

    @Test("Returns configured status output")
    func returnsStatusOutput() async throws {
        let mock = MockCommandRunner(statusOutput: "25% used")
        let output = try await mock.fetchStatus()
        #expect(output.stdout == "25% used")
        #expect(output.exitCode == 0)
    }

    @Test("Throws configured error")
    func throwsError() async throws {
        let mock = MockCommandRunner(statusError: CommandError.timeout(seconds: 5))
        await #expect(throws: CommandError.timeout(seconds: 5)) {
            try await mock.fetchStatus()
        }
    }

    @Test("fetchStats returns nil when not configured")
    func statsMissingReturnsNil() async throws {
        let mock = MockCommandRunner(statusOutput: "ok")
        #expect(try await mock.fetchStats() == nil)
    }

    @Test("fetchStats returns output when configured")
    func statsPresent() async throws {
        let mock = MockCommandRunner(statusOutput: "ok", statsOutput: "model table")
        let result = try await mock.fetchStats()
        #expect(result?.stdout == "model table")
    }
}

// MARK: - CLIPathDetector

@Suite("CLIPathDetector")
struct CLIPathDetectorTests {

    @Test("Detects /bin/echo as a valid executable")
    func detectsKnownBinary() {
        // Verify verify() works for a guaranteed binary
        #expect(CLIPathDetector.verify(path: "/bin/echo"))
    }

    @Test("Returns nil for non-existent path")
    func missingPath() {
        #expect(!CLIPathDetector.verify(path: "/does/not/exist/claude"))
    }

    @Test("Search directories are in expected order")
    func searchOrder() {
        #expect(CLIPathDetector.searchDirectories.first == "/opt/homebrew/bin")
        #expect(CLIPathDetector.searchDirectories.contains("/usr/local/bin"))
        #expect(CLIPathDetector.searchDirectories.contains("/usr/bin"))
    }
}

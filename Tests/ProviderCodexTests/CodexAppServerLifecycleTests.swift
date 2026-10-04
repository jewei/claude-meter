import Darwin
import Foundation
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    /// CDX-18: every way the child can end, against the live recovery. Step limits are at
    /// least 2 seconds, because the first run of a new script can take about half a second on
    /// a busy machine.
    @Suite struct CodexAppServerLifecycleTests {
        /// A child that ignores TERM and stdin EOF is killed after the grace period and reaped.
        @Test func aChildThatIgnoresTERMIsKilledAfterATimeout() async throws {
            let cli = try FakeCodexCLI(
                accountReply: ":", prelude: "trap '' TERM",
                epilogue: "while :; do sleep 1; done")
            defer { cli.root.remove() }
            await #expect(throws: CodexError.appServerTimedOut(step: "account/read")) {
                try await cli.server(stepLimit: .seconds(2))
                    .recover(cli.home, environment: cli.environment)
            }
            #expect(cli.childIsGone())
        }

        @Test func aChildThatIgnoresTERMIsKilledAfterASuccess() async throws {
            let cli = try FakeCodexCLI(
                prelude: "trap '' TERM", epilogue: "while :; do sleep 1; done")
            defer { cli.root.remove() }
            let reply = try await cli.server().recover(cli.home, environment: cli.environment)
            #expect(reply.rateLimits != nil)
            #expect(cli.childIsGone())
        }

        /// A response that arrives during the TERM grace, after the step timed out, never wins.
        @Test func aResponseDuringTheTERMGraceDoesNotWin() async throws {
            // On TERM, the child writes the account/read answer and exits. Whether the shell
            // runs the trap before the KILL depends on the load, so the test does not require
            // it; the timeout must win either way.
            let cli = try FakeCodexCLI(
                accountReply: "sleep 30 >/dev/null 2>&1 & pid=$!; wait $pid",
                prelude: #"""
                    root="$(dirname "$0")/.."
                    trap 'kill $pid 2>/dev/null; cat "$root/reply"; exit 0' TERM
                    """#)
            defer { cli.root.remove() }
            try cli.root.write(
                #"{"id":2,"result":{"account":{"type":"chatgpt"}}}"# + "\n", to: "reply")
            await #expect(throws: CodexError.appServerTimedOut(step: "account/read")) {
                try await cli.server(stepLimit: .seconds(2))
                    .recover(cli.home, environment: cli.environment)
            }
            #expect(cli.childIsGone())
        }

        @Test func aChildThatExitsAtOnceStoppedBeforeItAnswered() async throws {
            let cli = try FakeCodexCLI(prelude: "exit 3")
            defer { cli.root.remove() }
            await #expect(throws: CodexError.appServerStopped(step: "initialize", detail: nil)) {
                try await cli.server().recover(cli.home, environment: cli.environment)
            }
            #expect(cli.childIsGone())
        }

        /// A Codex without `app-server` says why on stderr and ends. Diagnostics keep its last
        /// line, and the card asks the user to update Codex.
        @Test func aChildThatEndsBeforeInitializeKeepsItsLastErrorLine() async throws {
            let cli = try FakeCodexCLI(
                prelude:
                    "echo 'usage: codex' >&2; echo \"error: unknown command 'app-server'\" >&2; exit 2"
            )
            defer { cli.root.remove() }
            let error = await #expect(throws: CodexError.self) {
                try await cli.server().recover(cli.home, environment: cli.environment)
            }
            #expect(
                error
                    == .appServerStopped(
                        step: "initialize", detail: "error: unknown command 'app-server'"))
            #expect(
                error?.localizedDescription
                    == "Codex CLI stopped before it answered. Update Codex, then refresh.")
            #expect(cli.childIsGone())
        }

        @Test func aChildThatEndsLaterAsksForATerminalCheck() async throws {
            let cli = try FakeCodexCLI(accountReply: "echo 'panic: lost' >&2; exit 4")
            defer { cli.root.remove() }
            let error = await #expect(throws: CodexError.self) {
                try await cli.server().recover(cli.home, environment: cli.environment)
            }
            #expect(error == .appServerStopped(step: "account/read", detail: "panic: lost"))
            #expect(error?.localizedDescription.contains("runs in Terminal") == true)
        }

        @Test func aCommandThatCannotStartFailsToLaunch() async throws {
            let cli = try FakeCodexCLI()
            defer { cli.root.remove() }
            try Data([0xCA, 0xFE, 0x00, 0x01, 0x02]).write(to: cli.executable)
            let error = await #expect(throws: CodexError.self) {
                try await cli.server().recover(cli.home, environment: cli.environment)
            }
            guard case .appServerLaunchFailed(let detail) = error else {
                Issue.record("Expected a launch failure, got \(String(describing: error))")
                return
            }
            #expect(detail?.isEmpty == false)
            #expect(
                error?.localizedDescription
                    == "Codex CLI could not start. Reinstall Codex, then refresh.")
        }

        @Test func aLineOverTheLimitIsUnexpected() async throws {
            let cli = try FakeCodexCLI(
                initializeReply:
                    "echo 'out of memory' >&2; head -c 1100000 /dev/zero | tr '\\0' 'a'; echo")
            defer { cli.root.remove() }
            await #expect(throws: CodexError.appServerUnexpected(detail: "out of memory")) {
                try await cli.server().recover(cli.home, environment: cli.environment)
            }
            #expect(cli.childIsGone())
        }

        @Test func anInitializeTimeoutNamesTheStep() async throws {
            let cli = try FakeCodexCLI(initializeReply: ":")
            defer { cli.root.remove() }
            await #expect(throws: CodexError.appServerTimedOut(step: "initialize")) {
                try await cli.server(stepLimit: .seconds(2))
                    .recover(cli.home, environment: cli.environment)
            }
            #expect(cli.requests().count == 1)
            #expect(cli.childIsGone())
        }

        @Test func anErrorReplyWithoutAMessageSaysSo() async throws {
            let cli = try FakeCodexCLI(
                rateLimitsReply: #"printf '%s\n' '{"id":3,"error":{"code":-32603}}'"#)
            defer { cli.root.remove() }
            await #expect(throws: CodexError.appServerFailed("no details")) {
                try await cli.server().recover(cli.home, environment: cli.environment)
            }
            #expect(cli.childIsGone())
        }
    }
}

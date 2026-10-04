import Darwin
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    /// Drives the live recovery against a small `/bin/sh` script that speaks the protocol.
    @Suite struct CodexAppServerTests {
        /// A fake `codex` that logs each request line, writes its PID, and answers by method.
        private struct FakeCLI {
            let root: TemporaryDirectory
            let executable: URL
            let home: CodexHome

            init(accountReply: String, rateLimitsReply: String) throws {
                root = try TemporaryDirectory()
                home = CodexHome(directory: try root.makeDirectory("home"), isImplicit: true)
                let log = root.path("requests.log").path
                let script = """
                    #!/bin/sh
                    echo $$ > '\(root.path("pid").path)'
                    printf '%s|%s\\n' "${OPENAI_API_KEY-unset}" "$CODEX_HOME" > '\(root.path("env").path)'
                    printf '%s\\n' "$*" > '\(root.path("args").path)'
                    while IFS= read -r line; do
                      printf '%s\\n' "$line" >> '\(log)'
                      case "$line" in
                        *'"method":"initialize"'*)
                          printf '%s\\n' 'not json' '{"id":1,"result":{"userAgent":"codex"}}' ;;
                        *'"method":"account/read"'*)
                          \(accountReply) ;;
                        *'"method":"account/rateLimits/read"'*)
                          \(rateLimitsReply) ;;
                      esac
                    done
                    """
                executable = try root.write(script, to: "bin/codex")
                #expect(chmod(executable.path, 0o755) == 0)
            }

            var environment: [String: String] {
                CodexEnvironment.scoped(
                    [
                        "CODEX_CLI_PATH": executable.path, "OPENAI_API_KEY": "sk-secret",
                        "PATH": "/usr/bin:/bin",
                    ],
                    home: home)
            }

            func requests() throws -> [String] {
                let text =
                    (try? String(contentsOf: root.path("requests.log"), encoding: .utf8)) ?? ""
                return text.split(separator: "\n").map(String.init)
            }

            func file(_ name: String) -> String {
                ((try? String(contentsOf: root.path(name), encoding: .utf8)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            /// The child no longer exists: it was stopped and reaped.
            func childIsGone() -> Bool {
                guard let pid = Int32(file("pid")) else { return false }
                return kill(pid, 0) != 0 && errno == ESRCH
            }
        }

        private static let accountReply = """
            printf '%s\\n' '{"method":"account/updated","params":{}}' '{"id":2,"method":"server/request","params":{}}' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}'
            """
        private static let rateLimitsReply = """
            printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":22,"windowDurationMins":300}}}}'
            """

        @Test func speaksTheProtocolAndReapsTheChild() async throws {
            let cli = try FakeCLI(
                accountReply: Self.accountReply, rateLimitsReply: Self.rateLimitsReply)
            defer { cli.root.remove() }
            let server = CodexAppServer(userHome: cli.root.url, stepLimit: .seconds(5))

            let reply = try await server.recover(cli.home, environment: cli.environment)

            #expect(reply.account?["account"]?["planType"]?.text == "plus")
            #expect(reply.rateLimits?["rateLimits"]?["primary"]?["usedPercent"]?.doubleValue == 22)
            #expect(
                try cli.requests() == [
                    #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-meter","version":"1"}}}"#,
                    #"{"method":"initialized","params":{}}"#,
                    #"{"id":2,"method":"account/read","params":{"refreshToken":true}}"#,
                    #"{"id":3,"method":"account/rateLimits/read","params":{}}"#,
                ])
            #expect(cli.file("args") == "-s read-only -a never app-server")
            #expect(cli.file("env") == "unset|\(cli.home.directory.path)")
            #expect(cli.childIsGone())
        }

        /// v3 bug 2: a timeout names the step that timed out.
        @Test func aTimeoutNamesTheStepAndStopsTheChild() async throws {
            let cli = try FakeCLI(accountReply: ":", rateLimitsReply: Self.rateLimitsReply)
            defer { cli.root.remove() }
            let server = CodexAppServer(userHome: cli.root.url, stepLimit: .seconds(2))
            await #expect(throws: CodexError.appServerTimedOut(step: "account/read")) {
                try await server.recover(cli.home, environment: cli.environment)
            }
            #expect(try cli.requests().count == 3)
            #expect(cli.childIsGone())
        }

        @Test func anErrorReplyToAccountReadStillReadsRateLimits() async throws {
            let cli = try FakeCLI(
                accountReply: #"printf '%s\n' '{"id":2,"error":{"code":-32600,"message":"busy"}}'"#,
                rateLimitsReply: Self.rateLimitsReply)
            defer { cli.root.remove() }
            let server = CodexAppServer(userHome: cli.root.url, stepLimit: .seconds(5))
            let reply = try await server.recover(cli.home, environment: cli.environment)
            #expect(reply.account == nil)
            #expect(reply.rateLimits != nil)
        }

        @Test func anAPIKeyAccountStopsBeforeRateLimits() async throws {
            let cli = try FakeCLI(
                accountReply: #"printf '%s\n' '{"id":2,"result":{"account":{"type":"apiKey"}}}'"#,
                rateLimitsReply: Self.rateLimitsReply)
            defer { cli.root.remove() }
            let server = CodexAppServer(userHome: cli.root.url, stepLimit: .seconds(5))
            let reply = try await server.recover(cli.home, environment: cli.environment)
            #expect(reply.rateLimits == nil)
            #expect(try cli.requests().count == 3)
            #expect(cli.childIsGone())
        }

        @Test func aRateLimitErrorFailsWithTheServerMessage() async throws {
            let cli = try FakeCLI(
                accountReply: Self.accountReply,
                rateLimitsReply:
                    #"printf '%s\n' '{"id":3,"error":{"message":"quota unavailable"}}'"#)
            defer { cli.root.remove() }
            let server = CodexAppServer(userHome: cli.root.url, stepLimit: .seconds(5))
            await #expect(throws: CodexError.appServerFailed("quota unavailable")) {
                try await server.recover(cli.home, environment: cli.environment)
            }
            #expect(cli.childIsGone())
        }

        @Test func cancellationDuringAccountReadStopsTheChild() async throws {
            let cli = try FakeCLI(accountReply: ":", rateLimitsReply: Self.rateLimitsReply)
            defer { cli.root.remove() }
            let server = CodexAppServer(userHome: cli.root.url, stepLimit: .seconds(10))
            let home = cli.home
            let environment = cli.environment
            let task = Task { try await server.recover(home, environment: environment) }
            try await Task.sleep(for: .milliseconds(500))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!(try cli.requests()).contains { $0.contains("rateLimits") })
            #expect(cli.childIsGone())
        }

        @Test func discoveryOrderAndChecks() async throws {
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let candidates = CodexExecutable.candidates(
                environment: ["CODEX_CLI_PATH": " /custom/codex ", "PATH": "/one::/two"],
                userHome: URL(fileURLWithPath: "/Users/me"))
            #expect(
                candidates.map(\.path) == [
                    "/custom/codex", "/one/codex", "/two/codex", "/opt/homebrew/bin/codex",
                    "/usr/local/bin/codex", "/Users/me/.local/bin/codex",
                    "/Users/me/.bun/bin/codex",
                    "/Users/me/.npm-global/bin/codex", "/Users/me/.volta/bin/codex",
                    "/Applications/Codex.app/Contents/Resources/codex", "/usr/bin/codex",
                ])

            let plain = try root.write("#!/bin/sh\n", to: "plain/codex")
            _ = try root.makeDirectory("folder/codex")
            let runnable = try root.write("#!/bin/sh\n", to: ".local/bin/codex")
            #expect(chmod(runnable.path, 0o755) == 0)
            let found = try await CodexExecutable.locate(
                environment: [
                    "CODEX_CLI_PATH": plain.path,
                    "PATH": "\(root.path("plain").path):\(root.path("folder").path)",
                ],
                userHome: root.url, timeout: .seconds(5))
            #expect(found.path != plain.path)
            #expect(!found.path.hasPrefix(root.path("folder").path))
            // A real Codex in an earlier install folder can win on a developer machine.
            if found.path.hasPrefix(root.url.path) {
                #expect(found.path == runnable.path)
            }
        }

        /// v3 bug 7: the message names no setting that does not exist.
        @Test func theMissingCLIMessageNamesNoSetting() {
            let message = CodexError.cliNotFound.localizedDescription
            #expect(!message.lowercased().contains("set "))
            #expect(!message.contains("path"))
        }

        @Test func theChildEnvironmentIsScrubbed() {
            var environment = Dictionary(
                uniqueKeysWithValues: CodexEnvironment.scrubbedVariables.map { ($0, "secret") })
            environment["PATH"] = "/usr/bin"
            environment["HOME"] = "/Users/me"
            environment["CODEX_HOME"] = "/Users/me/.codex"
            environment["UNRELATED"] = "kept"
            #expect(CodexEnvironment.scrubbedVariables.count == 15)
            #expect(
                CodexEnvironment.scrubbed(environment)
                    == [
                        "PATH": "/usr/bin", "HOME": "/Users/me", "CODEX_HOME": "/Users/me/.codex",
                        "UNRELATED": "kept",
                    ])
            #expect(CodexAppServer.arguments == ["-s", "read-only", "-a", "never", "app-server"])
        }
    }
}

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
        @Test func speaksTheProtocolAndReapsTheChild() async throws {
            let cli = try FakeCodexCLI()
            defer { cli.root.remove() }

            let reply = try await cli.server().recover(cli.home, environment: cli.environment)

            #expect(reply.account?["account"]?["planType"]?.text == "plus")
            #expect(reply.rateLimits?["rateLimits"]?["primary"]?["usedPercent"]?.doubleValue == 22)
            #expect(
                cli.requests() == [
                    #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-meter","version":"1"}}}"#,
                    #"{"method":"initialized","params":{}}"#,
                    #"{"id":2,"method":"account/read","params":{"refreshToken":true}}"#,
                    #"{"id":3,"method":"account/rateLimits/read","params":{}}"#,
                ])
            #expect(cli.file("args") == "-s read-only -a never app-server")
            let environment = cli.file("env").split(separator: "|").map(String.init)
            #expect(environment.prefix(2) == ["unset", cli.home.directory.path])
            let path = environment.last?.split(separator: ":").map(String.init) ?? []
            #expect(path.first == cli.executable.deletingLastPathComponent().path)
            #expect(path.contains("/usr/sbin"))
            #expect(cli.childIsGone())
        }

        /// CDX-01: an npm or bun install is `#!/usr/bin/env node`. A Finder launch has a short
        /// `PATH`, so the child's `PATH` must add the folders where the interpreter lives.
        @Test(arguments: ["prefix/bin/codex", "links/codex"])
        func aLauncherFindsItsInterpreterWithAShortPATH(command: String) async throws {
            let cli = try FakeCodexCLI(launcherAt: command)
            defer { cli.root.remove() }

            let reply = try await cli.server().recover(cli.home, environment: cli.environment)

            #expect(reply.rateLimits?["rateLimits"]?["primary"]?["usedPercent"]?.doubleValue == 22)
            #expect(cli.childIsGone())
        }

        @Test func theChildPathAddsTheCommandFoldersFirst() {
            let command = CodexExecutable.Command(
                url: URL(fileURLWithPath: "/Users/me/.local/bin/codex"),
                target: URL(
                    fileURLWithPath:
                        "/Users/me/.nvm/versions/node/v22/lib/node_modules/@openai/codex/bin/codex.js"
                ))
            let path = CodexEnvironment.childPath(
                for: command, environment: ["PATH": "/usr/bin:/bin::/Users/me/.local/bin"],
                installFolders: [
                    URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/bin"),
                ])
            #expect(
                path.split(separator: ":") == [
                    "/Users/me/.local/bin",
                    "/Users/me/.nvm/versions/node/v22/lib/node_modules/@openai/codex/bin",
                    "/Users/me/.nvm/versions/node/v22/bin", "/usr/bin", "/bin",
                    "/opt/homebrew/bin", "/usr/sbin", "/sbin",
                ])
        }

        /// The child keeps the app environment and its `PATH` change, without the scrubbed keys.
        @Test func theChildEnvironmentIsScrubbed() {
            var environment = Dictionary(
                uniqueKeysWithValues: CodexEnvironment.scrubbedVariables.map { ($0, "secret") })
            environment["PATH"] = "/usr/bin"
            environment["HOME"] = "/Users/me"
            environment["CODEX_HOME"] = "/Users/me/.codex"
            environment["UNRELATED"] = "kept"
            #expect(CodexEnvironment.scrubbedVariables.count == 15)
            let command = CodexExecutable.Command(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                target: URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
            #expect(
                CodexEnvironment.child(environment, command: command, installFolders: [])
                    == [
                        "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                        "HOME": "/Users/me", "CODEX_HOME": "/Users/me/.codex",
                        "UNRELATED": "kept",
                    ])
            #expect(CodexAppServer.arguments == ["-s", "read-only", "-a", "never", "app-server"])
        }

        /// CDX-21: the search uses only the folders that the test gives it.
        @Test func discoveryOrderAndChecks() async throws {
            let candidates = CodexExecutable.candidates(
                environment: ["CODEX_CLI_PATH": " /custom/codex ", "PATH": "/one::/two"],
                installFolders: CodexExecutable.installFolders(
                    userHome: URL(fileURLWithPath: "/Users/me")))
            #expect(
                candidates.map(\.path) == [
                    "/custom/codex", "/one/codex", "/two/codex", "/opt/homebrew/bin/codex",
                    "/usr/local/bin/codex", "/Users/me/.local/bin/codex",
                    "/Users/me/.bun/bin/codex",
                    "/Users/me/.npm-global/bin/codex", "/Users/me/.volta/bin/codex",
                    "/Applications/Codex.app/Contents/Resources/codex", "/usr/bin/codex",
                ])

            let root = try TemporaryDirectory()
            defer { root.remove() }
            let plain = try root.write("#!/bin/sh\n", to: "plain/codex")
            _ = try root.makeDirectory("folder/codex")
            let runnable = try root.write("#!/bin/sh\n", to: ".local/bin/codex")
            #expect(chmod(runnable.path, 0o755) == 0)
            try FileManager.default.createSymbolicLink(
                at: try root.makeDirectory("links").appending(path: "codex"),
                withDestinationURL: runnable)
            let environment = [
                "CODEX_CLI_PATH": plain.path,
                "PATH": "\(root.path("plain").path):\(root.path("folder").path)",
            ]

            let found = try await CodexExecutable.locate(
                environment: environment,
                installFolders: [root.path("missing"), root.path(".local/bin")],
                timeout: .seconds(5))
            #expect(found.url.path == runnable.path)

            let linked = try await CodexExecutable.locate(
                environment: [:], installFolders: [root.path("links")], timeout: .seconds(5))
            #expect(linked.url.path == root.path("links/codex").path)
            #expect(linked.target.path == runnable.path)

            await #expect(throws: CodexError.cliNotFound) {
                try await CodexExecutable.locate(
                    environment: environment, installFolders: [], timeout: .seconds(5))
            }
        }

        /// v3 bug 2: a timeout names the step that timed out.
        @Test func aTimeoutNamesTheStepAndStopsTheChild() async throws {
            let cli = try FakeCodexCLI(accountReply: ":")
            defer { cli.root.remove() }
            await #expect(throws: CodexError.appServerTimedOut(step: "account/read")) {
                try await cli.server(stepLimit: .seconds(2))
                    .recover(cli.home, environment: cli.environment)
            }
            #expect(cli.requests().count == 3)
            #expect(cli.childIsGone())
        }

        /// CDX-17: `account/read` renews the token over the network, so it gets the longer
        /// network limit, not the local step limit.
        @Test func aSlowAccountReadGetsTheNetworkLimit() async throws {
            let cli = try FakeCodexCLI(accountReply: "sleep 3.5; " + FakeCodexCLI.accountReply)
            defer { cli.root.remove() }
            let reply = try await cli.server(stepLimit: .seconds(3), networkStepLimit: .seconds(30))
                .recover(cli.home, environment: cli.environment)
            #expect(reply.account?["account"]?["planType"]?.text == "plus")
            #expect(reply.rateLimits != nil)
        }

        @Test func anErrorReplyToAccountReadStillReadsRateLimits() async throws {
            let cli = try FakeCodexCLI(
                accountReply: #"printf '%s\n' '{"id":2,"error":{"code":-32600,"message":"busy"}}'"#)
            defer { cli.root.remove() }
            let reply = try await cli.server().recover(cli.home, environment: cli.environment)
            #expect(reply.account == nil)
            #expect(reply.rateLimits != nil)
        }

        /// API-key auth has no subscription quota, and `"account": null` has no login.
        @Test(arguments: [
            #"{"type":"apiKey"}"#, "null",
        ])
        func anAccountWithoutQuotaStopsBeforeRateLimits(account: String) async throws {
            let cli = try FakeCodexCLI(
                accountReply: #"printf '%s\n' '{"id":2,"result":{"account":\#(account)}}'"#)
            defer { cli.root.remove() }
            let reply = try await cli.server().recover(cli.home, environment: cli.environment)
            #expect(reply.rateLimits == nil)
            #expect(cli.requests().count == 3)
            #expect(cli.childIsGone())
        }

        @Test func aRateLimitErrorFailsWithTheServerMessage() async throws {
            let cli = try FakeCodexCLI(
                rateLimitsReply:
                    #"printf '%s\n' '{"id":3,"error":{"message":"quota unavailable"}}'"#)
            defer { cli.root.remove() }
            await #expect(throws: CodexError.appServerFailed("quota unavailable")) {
                try await cli.server().recover(cli.home, environment: cli.environment)
            }
            #expect(cli.childIsGone())
        }

        @Test func cancellationDuringAccountReadStopsTheChild() async throws {
            let cli = try FakeCodexCLI(accountReply: ":")
            defer { cli.root.remove() }
            let server = cli.server(stepLimit: .seconds(10))
            let home = cli.home
            let environment = cli.environment
            let task = Task { try await server.recover(home, environment: environment) }
            // Cancel only once the child is waiting in account/read, not after a fixed delay.
            #expect(await cli.waitForRequest(containing: "account/read"))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!cli.requests().contains { $0.contains("rateLimits") })
            #expect(cli.childIsGone())
        }

        /// v3 bug 7: the message names no setting that does not exist.
        @Test func theMissingCLIMessageNamesNoSetting() {
            let message = CodexError.cliNotFound.localizedDescription
            #expect(!message.lowercased().contains("set "))
            #expect(!message.contains("path"))
        }
    }
}

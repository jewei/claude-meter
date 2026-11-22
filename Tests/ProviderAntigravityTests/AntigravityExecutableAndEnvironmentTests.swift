import Foundation
import MeterTestSupport
import Testing

@testable import ProviderAntigravity

@Suite struct AntigravityExecutableAndEnvironmentTests {
    @Test func candidateOrderPrefersExplicitPathThenPathThenInstallFolders() {
        let install = [URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)]
        let candidates = AntigravityExecutable.candidates(
            environment: [
                "ANTIGRAVITY_CLI_PATH": "  /custom/agy  ",
                "PATH": "/first/bin:/second/bin",
            ],
            installFolders: install)
        #expect(
            candidates.map(\.path) == [
                "/custom/agy",
                "/first/bin/agy",
                "/second/bin/agy",
                "/opt/homebrew/bin/agy",
            ])
    }

    @Test func locatesExecutableAndResolvesSymlink() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let real = try directory.write("#!/bin/sh\nexit 0\n", to: "real/agy")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        let link = directory.path("bin/agy")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let command = try await AntigravityExecutable.locate(
            environment: ["ANTIGRAVITY_CLI_PATH": link.path],
            installFolders: [],
            timeout: .seconds(5))
        #expect(command.url == link)
        #expect(command.target.path == real.resolvingSymlinksInPath().path)
    }

    @Test func throwsCliNotFoundWhenNoExecutableExists() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        await #expect(throws: AntigravityFailure.cliNotFound) {
            _ = try await AntigravityExecutable.locate(
                environment: ["PATH": directory.url.path],
                installFolders: [],
                timeout: .seconds(5))
        }
    }

    @Test func childEnvironmentScrubsProviderVariablesAndBuildsPath() {
        let command = AntigravityExecutable.Command(
            url: URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            target: URL(fileURLWithPath: "/opt/homebrew/Caskroom/agy/bin/agy"))
        let env = AntigravityEnvironment.child(
            [
                "HOME": "/Users/test",
                "PATH": "/opt/homebrew/bin:/usr/bin",
                "GEMINI_API_KEY": "AIza-secret",
                "GOOGLE_API_KEY": "AIza-secret-2",
                "ANTHROPIC_API_KEY": "sk-ant-secret",
                "OPENAI_API_KEY": "sk-openai-secret",
            ],
            command: command,
            installFolders: [URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)])
        #expect(env["HOME"] == "/Users/test")
        #expect(env["GEMINI_API_KEY"] == nil)
        #expect(env["GOOGLE_API_KEY"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(
            env["PATH"]
                == "/opt/homebrew/bin:/opt/homebrew/Caskroom/agy/bin:/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin"
        )
    }
}

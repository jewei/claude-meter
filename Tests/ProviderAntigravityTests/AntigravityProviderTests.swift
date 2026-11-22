import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderAntigravity

@Suite struct AntigravityProviderTests {
    private final class FakeCLI: AntigravityCLI {
        let usesCustomPath: Bool
        private let locateResult: Locked<Result<AntigravityExecutable.Command, any Error>>
        private let fetchResult: Locked<Result<Data, any Error>>

        init(
            usesCustomPath: Bool = false,
            locate: Result<AntigravityExecutable.Command, any Error> = .success(
                .init(
                    url: URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
                    target: URL(fileURLWithPath: "/opt/homebrew/bin/agy"))),
            fetch: Result<Data, any Error> = .success(AntigravityUsageResponseTests.recordedUsage)
        ) {
            self.usesCustomPath = usesCustomPath
            self.locateResult = Locked(locate)
            self.fetchResult = Locked(fetch)
        }

        func setLocate(_ result: Result<AntigravityExecutable.Command, any Error>) {
            locateResult.withLock { $0 = result }
        }

        func setFetch(_ result: Result<Data, any Error>) {
            fetchResult.withLock { $0 = result }
        }

        func locate() async throws -> AntigravityExecutable.Command {
            try locateResult.value.get()
        }

        func fetchUsage(using _: AntigravityExecutable.Command) async throws -> Data {
            try fetchResult.value.get()
        }
    }

    @Test func fetchReturnsObservedAccountWithoutOwner() async throws {
        let now = Date.reference()
        let provider = AntigravityProvider(cli: FakeCLI(), now: { now })
        let usage = try await provider.fetch(previous: nil)
        #expect(usage.provider == .antigravity)
        let account = try #require(usage.account(.default))
        #expect(account.name == "Antigravity")
        #expect(account.observedAt == now)
        #expect(account.owner == nil)
        #expect(account.issue == nil)
        #expect(account.windows.count == 5)
    }

    @Test func transientFailureKeepsPreviousObservationAsStale() async throws {
        let cli = FakeCLI()
        let provider = AntigravityProvider(cli: cli, now: { .reference() })
        let first = try await provider.fetch(previous: nil)

        cli.setFetch(.failure(AntigravityFailure.timedOut))
        let second = try await provider.fetch(previous: first)
        let account = try #require(second.account(.default))
        #expect(account.hasObservation)
        #expect(account.isStale)
        #expect(account.issue == AntigravityFailure.timedOut.issue)
    }

    @Test func signedOutAndMissingCliDropPreviousObservation() async throws {
        let cli = FakeCLI()
        let provider = AntigravityProvider(cli: cli, now: { .reference() })
        let first = try await provider.fetch(previous: nil)

        cli.setFetch(.failure(AntigravityFailure.signedOut))
        let signedOut = try await provider.fetch(previous: first)
        let signedOutAccount = try #require(signedOut.account(.default))
        #expect(!signedOutAccount.hasObservation)
        #expect(signedOutAccount.issue == AntigravityFailure.signedOut.issue)

        cli.setLocate(.failure(AntigravityFailure.cliNotFound))
        let missing = try await provider.fetch(previous: first)
        let missingAccount = try #require(missing.account(.default))
        #expect(!missingAccount.hasObservation)
        #expect(missingAccount.issue == AntigravityFailure.cliNotFound.issue)
    }

    @Test func reconcileDropsReadingOnlyWhenCliIsMissing() async throws {
        let cli = FakeCLI()
        let provider = AntigravityProvider(cli: cli, now: { .reference() })
        let first = try await provider.fetch(previous: nil)

        #expect(await provider.reconcile(first) == first)

        cli.setLocate(.failure(AntigravityFailure.cliSearchFailed))
        #expect(await provider.reconcile(first) == first)

        cli.setLocate(.failure(AntigravityFailure.cliNotFound))
        #expect(await provider.reconcile(first) == nil)
    }

    @Test func diagnosticsReportsCliPathAndRedactedRequestOutcome() async throws {
        let cli = FakeCLI(
            usesCustomPath: true,
            fetch: .failure(
                AntigravityFailure.commandFailed(
                    detail: "token ya29.a0AfH6SMC_0123456789abcdef failed")))
        let provider = AntigravityProvider(cli: cli, now: { .reference() })
        _ = try await provider.fetch(previous: nil)
        let facts = await provider.diagnostics()
        #expect(facts.first == DiagnosticFact("ANTIGRAVITY_CLI_PATH", "Set"))
        #expect(facts.contains(DiagnosticFact("CLI", "/opt/homebrew/bin/agy")))
        let last = try #require(facts.first { $0.label == "Last usage request" })
        #expect(last.value.contains("[redacted]"))
        #expect(!last.value.contains("ya29."))
    }

    @Test func liveCliParsesJsonSkippingBannerLines() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let json = String(decoding: AntigravityUsageResponseTests.recordedUsage, as: UTF8.self)
        let script = """
            #!/bin/sh
            echo "starting antigravity..."
            printf '%s\\n' '\(json)'
            """
        let executable = try directory.write(script, to: "agy")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let cli = LiveAntigravityCLI(
            environment: ["ANTIGRAVITY_CLI_PATH": executable.path],
            userHome: directory.url,
            installFolders: [],
            commandDeadline: .seconds(5))
        let command = try await cli.locate()
        let data = try await cli.fetchUsage(using: command)
        let parsed = try AntigravityUsageResponse(data: data)
        #expect(parsed.windows.count == 5)
    }

    @Test func liveCliStopsImmediatelyWhenStderrAsksForSignIn() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let script = """
            #!/bin/sh
            echo "Authentication required. Please visit the URL to log in:" >&2
            echo "  https://accounts.google.com/o/oauth2/auth" >&2
            sleep 30
            """
        let executable = try directory.write(script, to: "agy")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let cli = LiveAntigravityCLI(
            environment: ["ANTIGRAVITY_CLI_PATH": executable.path],
            userHome: directory.url,
            installFolders: [],
            commandDeadline: .seconds(15))
        let command = try await cli.locate()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: AntigravityFailure.signedOut) {
            _ = try await cli.fetchUsage(using: command)
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func liveCliTimesOutWhenProcessHangs() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let executable = try directory.write("#!/bin/sh\nsleep 30\n", to: "agy")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let cli = LiveAntigravityCLI(
            environment: ["ANTIGRAVITY_CLI_PATH": executable.path],
            userHome: directory.url,
            installFolders: [],
            commandDeadline: .milliseconds(300))
        let command = try await cli.locate()
        await #expect(throws: AntigravityFailure.timedOut) {
            _ = try await cli.fetchUsage(using: command)
        }
    }

    /// A fast-exiting child whose multi-line stderr ends with a URL must still be classified as
    /// `.signedOut` rather than `.commandFailed` so stale quota is dropped.
    @Test func liveCliClassifiesFastMultiLineSignInStderrAsSignedOut() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let script = """
            #!/bin/sh
            echo "Authentication required. Please visit the URL to log in:" >&2
            echo "  https://accounts.google.com/o/oauth2/auth" >&2
            exit 1
            """
        let executable = try directory.write(script, to: "agy")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let cli = LiveAntigravityCLI(
            environment: ["ANTIGRAVITY_CLI_PATH": executable.path],
            userHome: directory.url,
            installFolders: [],
            commandDeadline: .seconds(5))
        let command = try await cli.locate()
        await #expect(throws: AntigravityFailure.signedOut) {
            _ = try await cli.fetchUsage(using: command)
        }
    }

    @Test func liveCliAcceptsJsonWithoutTrailingNewline() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let json = String(decoding: AntigravityUsageResponseTests.recordedUsage, as: UTF8.self)
        let executable = try directory.write("#!/bin/sh\nprintf '%s' '\(json)'", to: "agy")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let cli = LiveAntigravityCLI(
            environment: ["ANTIGRAVITY_CLI_PATH": executable.path],
            userHome: directory.url,
            installFolders: [],
            commandDeadline: .seconds(5))
        let command = try await cli.locate()
        let data = try await cli.fetchUsage(using: command)
        let parsed = try AntigravityUsageResponse(data: data)
        #expect(parsed.windows.count == 5)
    }
}

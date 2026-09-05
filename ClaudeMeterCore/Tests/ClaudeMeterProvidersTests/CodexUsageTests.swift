import Darwin
import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("Codex usage", .serialized)
struct CodexUsageTests {

    @Test func appServerUsesSupportedNonInteractiveArguments() {
        #expect(
            CodexAppServerClient.processArguments
                == ["-s", "read-only", "-a", "never", "app-server"])
    }

    @Test func appServerTimeoutKillsAndReapsAChildThatIgnoresTerm() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-shutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("ignore-term.sh")
        let pidFile = directory.appendingPathComponent("pid")
        let script = """
            #!/bin/sh
            trap '' TERM
            printf '%s' "$$" > "$SHUTDOWN_PID_FILE"
            while :; do :; done
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = try CodexAppServerClient(
            executable: executable.path,
            env: ["SHUTDOWN_PID_FILE": pidFile.path],
            startupTimeout: 0.01,
            requestTimeout: 1)
        defer { client.shutdown() }

        let markerDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: pidFile.path),
            ProcessInfo.processInfo.systemUptime < markerDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: pidFile.path))
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(pidText))

        let start = ProcessInfo.processInfo.systemUptime
        do {
            try await client.initialize()
            Issue.record("Expected the unresponsive child to time out")
        } catch {
            #expect(error as? CodexUsageError == .rpcTimedOut("initialize"))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(elapsed < 2)
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func appServerTimeoutRejectsAResponseDuringTerminationGrace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-timeout-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("late-response.sh")
        let readyMarker = directory.appendingPathComponent("ready")
        let responseMarker = directory.appendingPathComponent("response")
        let script = """
            #!/bin/sh
            on_term() {
              printf '{"id":1,"result":{}}\n'
              : > "$RESPONSE_MARKER"
              trap '' TERM
              while :; do :; done
            }
            trap on_term TERM
            : > "$READY_MARKER"
            while :; do
              if IFS= read -r request; then
                :
              else
                while :; do :; done
              fi
            done
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = try CodexAppServerClient(
            executable: executable.path,
            env: ["READY_MARKER": readyMarker.path, "RESPONSE_MARKER": responseMarker.path],
            startupTimeout: 0.02,
            requestTimeout: 1)
        defer { client.shutdown() }

        // Other process tests run in parallel and can briefly saturate the test
        // host. Wait for the trap to be installed before testing the timeout race.
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: readyMarker.path),
            ProcessInfo.processInfo.systemUptime < readyDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: readyMarker.path))

        await #expect(throws: CodexUsageError.rpcTimedOut("initialize")) {
            try await client.initialize()
        }
        #expect(FileManager.default.fileExists(atPath: responseMarker.path))
    }

    @Test func appServerCancellationDuringAccountReadDoesNotRequestRateLimits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("cancel-account.sh")
        let accountMarker = directory.appendingPathComponent("account")
        let limitsMarker = directory.appendingPathComponent("limits")
        let script = """
            #!/bin/sh
            while IFS= read -r request; do
              case "$request" in
                *'"method":"initialize"'*)
                  printf '{"id":1,"result":{}}\n'
                  ;;
                *rateLimits*)
                  : > "$LIMITS_MARKER"
                  ;;
                *account*read*)
                  : > "$ACCOUNT_MARKER"
                  while :; do :; done
                  ;;
              esac
            done
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let source = CodexAppServerSource(
            env: ["ACCOUNT_MARKER": accountMarker.path, "LIMITS_MARKER": limitsMarker.path],
            // This test cancels on the account marker. Process startup under CI
            // load must not turn it into a startup- or request-timeout test.
            startupTimeout: 10,
            requestTimeout: 20,
            resolver: { _ in executable.path })
        let task = Task { try await source.fetchUsage(now: Date()) }
        defer { task.cancel() }

        let markerDeadline = ProcessInfo.processInfo.systemUptime + 10
        while !FileManager.default.fileExists(atPath: accountMarker.path),
            ProcessInfo.processInfo.systemUptime < markerDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: accountMarker.path))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: limitsMarker.path))
    }

    @Test func boundedProcessCaptureRejectsOverflowInsteadOfReturningATruncatedPrefix() {
        let capture = BoundedProcessOutputCapture(maxBytes: 4)
        capture.append(Data("ab".utf8))
        #expect(capture.data == Data("ab".utf8))

        capture.append(Data("cde".utf8))
        #expect(capture.data == nil)

        capture.append(Data("f".utf8))
        #expect(capture.data == nil)
    }

    @Test func boundedLineBufferHandlesSplitLinesAndRejectsAnOversizedTail() {
        let buffer = BoundedProcessLineBuffer(maxBytes: 4)
        let first = buffer.appendAndDrainLines(Data("ab\nc".utf8))
        #expect(first.lines == [Data("ab".utf8)])
        #expect(!first.exceededLimit)

        let second = buffer.appendAndDrainLines(Data("d\n".utf8))
        #expect(second.lines == [Data("cd".utf8)])
        #expect(!second.exceededLimit)

        let overflow = buffer.appendAndDrainLines(Data("abcde".utf8))
        #expect(overflow.lines.isEmpty)
        #expect(overflow.exceededLimit)
    }

    @Test func mapsAppServerRateLimitsToEnergyWindows() throws {
        let json = """
            {
              "rateLimits": {
                "planType": "pro",
                "primary": { "usedPercent": 22, "windowDurationMins": 300, "resetsAt": 1766948068 },
                "secondary": { "usedPercent": 43, "windowDurationMins": 10080, "resetsAt": 1767407914 },
                "credits": { "hasCredits": true, "unlimited": false, "balance": "112.4" }
              },
              "rateLimitResetCredits": {
                "availableCount": 4,
                "credits": [
                  { "title": "Full reset", "expiresAt": 1751100000 },
                  { "title": "Full reset", "expiresAt": 1752592200 }
                ]
              }
            }
            """
        let response = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_751_000_000)
        let usage = try response.usage(
            account: CodexAppServerAccount(
                email: "alpha@example.com", plan: nil, authMode: .chatGPT),
            now: now,
            source: .appServer)

        #expect(usage.primaryWindow?.usedPercent == 22)
        #expect(usage.primaryWindow?.energyLeftPercent == 78)
        #expect(usage.primaryWindow?.durationSeconds == 18_000)
        #expect(usage.primaryWindow?.displayLabel == "5h")
        #expect(usage.secondaryWindow?.usedPercent == 43)
        #expect(usage.secondaryWindow?.energyLeftPercent == 57)
        #expect(usage.secondaryWindow?.displayLabel == "Weekly")
        #expect(usage.usageCredits?.remaining == 112.4)
        #expect(usage.plan == "pro")
        #expect(usage.displayPlanName == "Pro 20X")
        #expect(usage.rateLimitResets?.availableCount == 4)
        #expect(usage.rateLimitResets?.credits?.count == 2)
        #expect(
            usage.rateLimitResets?.nearestExpiration(after: now)
                == Date(timeIntervalSince1970: 1_751_100_000))
        #expect(usage.maskedAccountEmail == "a***@example.com")
        #expect(usage.authMode == .chatGPT)
        #expect(usage.source == .appServer)
    }

    @Test func derivesWindowsFromRateLimitsByLimitIdWhenPositionalPairAbsent() throws {
        let json = """
            {
              "rateLimits": {
                "planType": "pro",
                "rateLimitsByLimitId": {
                  "codex_5h": { "usedPercent": 31, "windowDurationMins": 300, "resetsAt": 1766948068 },
                  "codex_burst": { "usedPercent": 12, "windowDurationMins": 60 },
                  "codex_weekly": { "usedPercent": 64, "windowDurationMins": 10080, "resetsAt": 1767407914 }
                }
              }
            }
            """
        let response = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))
        let usage = try response.usage(
            account: nil, now: Date(timeIntervalSince1970: 1_751_000_000), source: .appServer)

        // Most-used window per duration bucket wins; the limit id becomes the label.
        #expect(usage.primaryWindow?.usedPercent == 31)
        #expect(usage.primaryWindow?.displayLabel == "codex_5h")
        #expect(usage.secondaryWindow?.usedPercent == 64)
        #expect(usage.secondaryWindow?.displayLabel == "codex_weekly")
    }

    @Test func positionalWindowsStillWinOverByLimitId() throws {
        let json = """
            {
              "rateLimits": {
                "primary": { "usedPercent": 22, "windowDurationMins": 300 },
                "secondary": { "usedPercent": 43, "windowDurationMins": 10080 },
                "rateLimitsByLimitId": {
                  "codex_5h": { "usedPercent": 99, "windowDurationMins": 300 }
                }
              }
            }
            """
        let response = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))
        let usage = try response.usage(
            account: nil, now: Date(timeIntervalSince1970: 1_751_000_000), source: .appServer)

        #expect(usage.primaryWindow?.usedPercent == 22)
        #expect(usage.secondaryWindow?.usedPercent == 43)
    }

    @Test func keyedWindowsFillOnlyMissingPositionalWindow() throws {
        let json = """
            {"rateLimits":{
              "primary":{"usedPercent":22,"windowDurationMins":300},
              "rateLimitsByLimitId":{
                "codex_5h":{"usedPercent":99,"windowDurationMins":300},
                "codex_weekly":{"usedPercent":64,"windowDurationMins":10080}
              }
            }}
            """
        let response = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))
        let usage = try response.usage(account: nil, now: Date(), source: .appServer)
        #expect(usage.primaryWindow?.usedPercent == 22)
        #expect(usage.secondaryWindow?.usedPercent == 64)
    }

    @Test func formatsCurrentPlanNames() {
        let expected = [
            "go": "Go",
            "plus": "Plus",
            "prolite": "Pro 5X",
            "pro": "Pro 20X",
        ]
        for (raw, display) in expected {
            let usage = CodexUsage(
                primaryWindow: nil,
                secondaryWindow: nil,
                usageCredits: nil,
                accountEmail: nil,
                plan: raw,
                source: .appServer,
                updatedAt: Date())
            #expect(usage.displayPlanName == display)
        }
    }

    @Test func resetCountRemainsAuthoritativeWhenDetailsAreMissing() {
        let resets = CodexRateLimitResets(availableCount: 4, credits: nil)

        #expect(resets.availableCount == 4)
        #expect(resets.nearestExpiration(after: Date()) == nil)
    }

    @Test func unknownPercentDoesNotBecomeZeroEnergy() {
        let window = CodexLimitWindow(
            kind: .primary,
            usedPercent: nil,
            resetAt: nil,
            durationSeconds: 86_400,
            rawLabel: nil)

        #expect(window.energyLeftPercent == nil)
        #expect(window.displayLabel == "24h")
    }

    @Test func invalidExternalNumbersDoNotTrapOrBecomeUsage() {
        let window = CodexLimitWindow(
            kind: .primary,
            usedPercent: .nan,
            resetAt: nil,
            durationSeconds: .greatestFiniteMagnitude,
            rawLabel: nil)

        #expect(window.usedPercent == nil)
        #expect(window.durationSeconds == nil)
        #expect(window.displayLabel == "Session")
    }

    @Test func extremeAppServerDurationDoesNotOverflow() throws {
        let json = """
            {"rateLimits":{"primary":{
              "usedPercent":25,
              "windowDurationMins":9223372036854775807
            }}}
            """
        let response = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))
        let usage = try response.usage(account: nil, now: Date(), source: .appServer)

        #expect(usage.primaryWindow?.usedPercent == 25)
        #expect(usage.primaryWindow?.durationSeconds == nil)
        #expect(usage.primaryWindow?.displayLabel == "Session")
    }

    @Test func restoredLimitWindowUsesTheValidatedInitializer() throws {
        let json = #"{"kind":"primary","usedPercent":1e308,"durationSeconds":1e308}"#

        let window = try JSONDecoder().decode(CodexLimitWindow.self, from: Data(json.utf8))

        #expect(window.usedPercent == 100)
        #expect(window.durationSeconds == nil)
    }

    @Test func restoredCodexDatesStayInsideThePersistenceInterval() throws {
        let windowJSON = #"{"kind":"primary","resetAt":1e308}"#
        let window = try JSONDecoder().decode(CodexLimitWindow.self, from: Data(windowJSON.utf8))
        #expect(window.resetAt == nil)

        let creditJSON = #"{"title":"Reset","expiresAt":1e308}"#
        let credit = try JSONDecoder().decode(
            CodexRateLimitResetCredit.self, from: Data(creditJSON.utf8))
        #expect(credit.expiresAt == nil)
    }

    @Test func extremeCodexEpochsDoNotReachPersistedModels() throws {
        let json = """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 25,
                  "resetsAt": 9223372036854775807
                }
              },
              "rateLimitResetCredits": {
                "availableCount": 1,
                "credits": [{
                  "title": "Reset",
                  "expiresAt": 9223372036854775807
                }]
              }
            }
            """
        let response = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))
        let usage = try response.usage(account: nil, now: Date(), source: .appServer)

        #expect(usage.primaryWindow?.resetAt == nil)
        #expect(usage.rateLimitResets?.credits?.first?.expiresAt == nil)
        #expect(try JSONEncoder().encode(usage).isEmpty == false)
    }

    @Test func appServerRejectsNonFiniteCreditBalance() throws {
        let json = #"{"rateLimits":{"credits":{"unlimited":false,"balance":"inf"}}}"#
        let response = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))

        #expect(throws: CodexUsageError.noUsageData) {
            try response.usage(account: nil, now: Date(), source: .appServer)
        }
    }

    @Test func directOAuthRejectsNonFiniteCreditBalance() throws {
        let json = #"{"credits":{"unlimited":false,"balance":"nan"}}"#
        let response = try JSONDecoder().decode(CodexOAuthUsageResponse.self, from: Data(json.utf8))

        #expect(throws: CodexUsageError.noUsageData) {
            try response.usage(accountEmail: nil, now: Date(), source: .directOAuth)
        }
    }

    @Test(arguments: [#"{"balance":[]}"#, #"{"unlimited":"invalid"}"#, "[]", "null"])
    func malformedOAuthCreditsPreserveQuota(credits: String) throws {
        let json = """
            {"rate_limit":{"primary_window":{"used_percent":37}},
             "plan_type":[],"credits":\(credits)}
            """
        let response = try JSONDecoder().decode(CodexOAuthUsageResponse.self, from: Data(json.utf8))
        let usage = try response.usage(accountEmail: nil, now: Date(), source: .directOAuth)
        #expect(usage.primaryWindow?.usedPercent == 37)
        #expect(usage.usageCredits == nil)
        #expect(usage.plan == nil)
    }

    @Test func malformedOptionalMetadataDoesNotCreateUsage() throws {
        let oauth = try JSONDecoder().decode(
            CodexOAuthUsageResponse.self, from: Data(#"{"credits":{"balance":[]}}"#.utf8))
        #expect(throws: CodexUsageError.noUsageData) {
            try oauth.usage(accountEmail: nil, now: Date(), source: .directOAuth)
        }
        let appServer = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self,
            from: Data(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":[]}}"#.utf8))
        #expect(throws: CodexUsageError.noUsageData) {
            try appServer.usage(account: nil, now: Date(), source: .appServer)
        }
    }

    @Test func malformedOAuthQuotaStillFails() {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":[]}},"credits":null}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CodexOAuthUsageResponse.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [#"{"availableCount":[]}"#, "[]", "null"])
    func malformedResetMetadataPreservesQuota(metadata: String) throws {
        let json = """
            {"rateLimits":{"primary":{"usedPercent":37}},"rateLimitResetCredits":\(metadata)}
            """
        let response = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))
        let usage = try response.usage(account: nil, now: Date(), source: .appServer)
        #expect(usage.primaryWindow?.usedPercent == 37)
        #expect(usage.rateLimitResets == nil)
    }

    @Test func malformedResetDetailsPreserveAuthoritativeCount() throws {
        let json =
            #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":3,"credits":"invalid"}}"#
        let response = try JSONDecoder().decode(
            CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))
        let usage = try response.usage(account: nil, now: Date(), source: .appServer)
        #expect(usage.rateLimitResets?.availableCount == 3)
        #expect(usage.rateLimitResets?.credits == nil)
    }

    @Test func displayPercentRespectsProgressionMode() {
        let window = CodexLimitWindow(
            kind: .primary,
            usedPercent: 82,
            resetAt: nil,
            durationSeconds: 18_000,
            rawLabel: nil)

        #expect(window.displayPercent(showUsage: true) == 82)
        #expect(window.displayPercent(showUsage: false) == 18)
    }

    @Test func decodesOAuthUsageWithoutRequiringAllWindows() throws {
        let json = """
            {
              "plan_type": "plus",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 9,
                  "reset_at": 1766948068,
                  "limit_window_seconds": 18000
                },
                "secondary_window": null
              },
              "credits": { "has_credits": true, "unlimited": false, "balance": "7.5" }
            }
            """
        let response = try JSONDecoder().decode(CodexOAuthUsageResponse.self, from: Data(json.utf8))
        let usage = try response.usage(
            accountEmail: nil,
            now: Date(timeIntervalSince1970: 1_766_000_000),
            source: .directOAuth)

        #expect(usage.primaryWindow?.usedPercent == 9)
        #expect(usage.secondaryWindow == nil)
        #expect(usage.usageCredits?.remaining == 7.5)
        #expect(usage.plan == "plus")
        #expect(usage.authMode == .chatGPT)
        #expect(usage.source == .directOAuth)
    }

    @Test func directOAuthCredentialsAreReadOnlyAndRejectApiKeyOnlyFiles() throws {
        let tokenJSON = """
            {
              "tokens": {
                "access_token": "access",
                "refresh_token": "refresh",
                "id_token": "id",
                "account_id": "account"
              }
            }
            """
        let creds = try CodexOAuthCredentialsStore.parse(data: Data(tokenJSON.utf8))
        #expect(creds.accessToken == "access")
        #expect(creds.accountId == "account")

        let apiKeyJSON = #"{"OPENAI_API_KEY":"sk-test"}"#
        #expect(throws: CodexOAuthCredentialsError.apiKeyOnly) {
            try CodexOAuthCredentialsStore.parse(data: Data(apiKeyJSON.utf8))
        }
    }

    @Test func unreadableOAuthCredentialPathMapsToDomainError() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let authDirectory = home.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(
            at: authDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: CodexOAuthCredentialsError.unreadable) {
            try CodexOAuthCredentialsStore.load(env: ["CODEX_HOME": home.path])
        }
    }

    @Test func specialOAuthCredentialPathDoesNotBlock() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let authFile = home.appendingPathComponent("auth.json")
        #expect(authFile.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)

        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: CodexOAuthCredentialsError.unreadable) {
            try CodexOAuthCredentialsStore.load(env: ["CODEX_HOME": home.path])
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func sourceModeDefaultsToAutoForUnknownStoredValue() {
        #expect(CodexSourceMode(rawValue: "appServer") == .appServer)
        #expect(CodexSourceMode(rawValue: "directOAuth") == .directOAuth)
        #expect(CodexSourceMode.normalized("bad-value") == .auto)
    }

    @Test func providerAutoPrefersAppServer() async throws {
        let appServer = StubCodexSource(
            usage: Self.usage(source: .appServer),
            availability: true)
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth),
            availability: true)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)

        let usage = try await provider.fetchUsage(mode: .auto)

        #expect(usage.source == .appServer)
        #expect(appServer.fetchCount == 1)
        #expect(oauth.fetchCount == 0)
    }

    @Test func providerAutoFallsBackToOAuthWhenAppServerUnavailable() async throws {
        let appServer = StubCodexSource(
            usage: Self.usage(source: .appServer),
            availability: false)
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth),
            availability: true)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)

        let usage = try await provider.fetchUsage(mode: .auto)

        #expect(usage.source == .directOAuth)
        #expect(appServer.fetchCount == 1)
        #expect(oauth.fetchCount == 1)
    }

    @Test func providerDirectOAuthModeSkipsAppServer() async throws {
        let appServer = StubCodexSource(
            usage: Self.usage(source: .appServer),
            availability: true)
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth),
            availability: true)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)

        let usage = try await provider.fetchUsage(mode: .directOAuth)

        #expect(usage.source == .directOAuth)
        #expect(appServer.fetchCount == 0)
        #expect(oauth.fetchCount == 1)
    }

    /// The app-server fetch begins but its RPC fails. This is the common
    /// real-world failure — a codex build whose `app-server`
    /// subcommand is missing or slow — and it must still reach the OAuth source,
    /// which reads `auth.json` over HTTPS and is unaffected by the CLI.
    @Test func providerAutoFallsBackWhenAppServerFailsMidFetch() async throws {
        let appServer = StubCodexSource(
            usage: Self.usage(source: .appServer),
            availability: true,
            fetchError: CodexUsageError.rpcTimedOut("initialize"))
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth),
            availability: true)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)

        let usage = try await provider.fetchUsage(mode: .auto)

        #expect(usage.source == .directOAuth)
        #expect(appServer.fetchCount == 1)
        #expect(oauth.fetchCount == 1)
    }

    @Test func providerAutoDoesNotFallbackAfterAppServerCancellation() async {
        let appServer = StubCodexSource(
            usage: Self.usage(source: .appServer),
            availability: true,
            fetchError: CancellationError())
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth),
            availability: true)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)

        await #expect(throws: CancellationError.self) {
            try await provider.fetchUsage(mode: .auto)
        }
        #expect(appServer.fetchCount == 1)
        #expect(oauth.fetchCount == 0)
    }

    @Test func providerAutoPreservesOAuthCancellation() async {
        let appServer = StubCodexSource(
            usage: Self.usage(source: .appServer),
            availability: true,
            fetchError: CodexUsageError.rpcFailed("boom"))
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth),
            availability: true,
            fetchError: CancellationError())
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)

        await #expect(throws: CancellationError.self) {
            try await provider.fetchUsage(mode: .auto)
        }
        #expect(appServer.fetchCount == 1)
        #expect(oauth.fetchCount == 1)
    }

    @Test func providerReportsBothErrorsWhenOAuthAlsoFails() async {
        let appServer = StubCodexSource(
            usage: Self.usage(source: .appServer),
            availability: true,
            fetchError: CodexUsageError.rpcFailed("boom"))
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth),
            availability: false,
            unavailableError: CodexOAuthCredentialsError.notFound)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)

        await #expect(
            throws: CodexUsageError.allSourcesFailed(
                appServer: "Codex CLI request failed: boom",
                directOAuth: "Codex auth file not found; using Codex CLI if available.")
        ) {
            try await provider.fetchUsage(mode: .auto)
        }
    }

    @Test func providerReportsBothSourcesUnavailable() async {
        let appServer = StubCodexSource(
            usage: Self.usage(source: .appServer),
            availability: false,
            unavailableError: CodexUsageError.cliNotFound)
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth),
            availability: false,
            unavailableError: CodexOAuthCredentialsError.notFound)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)

        await #expect(
            throws: CodexUsageError.allSourcesFailed(
                appServer: "Codex CLI not found. Install Codex or set the Codex CLI path.",
                directOAuth: "Codex auth file not found; using Codex CLI if available.")
        ) {
            try await provider.fetchUsage(mode: .auto)
        }
    }

    @Test func decodesAppServerAccountResponse() throws {
        let json = """
            {
              "account": {
                "type": "chatgpt",
                "email": "beta@example.com",
                "planType": "plus"
              },
              "requiresOpenaiAuth": false
            }
            """
        let response = try JSONDecoder().decode(
            CodexAppServerAccountResponse.self, from: Data(json.utf8))

        #expect(response.account.email == "beta@example.com")
        #expect(response.account.plan == "plus")
        #expect(response.account.authMode == .chatGPT)
    }

    @Test func cliLocatorUsesExplicitEnvironmentPathWhenExecutable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-cli-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let executable = tempDir.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = CodexCLILocator.resolve(env: ["CODEX_CLI_PATH": executable.path])

        #expect(resolved == executable.path)
    }

    @Test func directOAuthSourceFetchesWhamUsageReadOnly() async throws {
        let json = """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 12,
                  "reset_at": 1766948068,
                  "limit_window_seconds": 18000
                }
              },
              "credits": { "balance": "5" }
            }
            """
        let transport = RecordingTransport(data: Data(json.utf8), status: 200)
        let source = CodexDirectOAuthSource(
            transport: transport,
            credentialsLoader: {
                CodexOAuthCredentials(
                    accessToken: "access-token",
                    refreshToken: "refresh-token",
                    idToken: nil,
                    accountId: "account-id")
            })

        let usage = try await source.fetchUsage(now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(usage.source == .directOAuth)
        #expect(usage.authMode == .chatGPT)
        #expect(usage.primaryWindow?.usedPercent == 12)
        #expect(
            transport.lastRequest?.url?.absoluteString
                == "https://chatgpt.com/backend-api/wham/usage")
        #expect(
            transport.lastRequest?.value(forHTTPHeaderField: "Authorization")
                == "Bearer access-token")
        #expect(
            transport.lastRequest?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-id")
    }

    private static func usage(source: CodexUsageSource) -> CodexUsage {
        CodexUsage(
            primaryWindow: CodexLimitWindow(
                kind: .primary,
                usedPercent: source == .appServer ? 10 : 20,
                resetAt: nil,
                durationSeconds: 18_000,
                rawLabel: nil),
            secondaryWindow: nil,
            usageCredits: nil,
            accountEmail: nil,
            plan: nil,
            source: source,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private final class StubCodexSource: CodexUsageSourceFetching, @unchecked Sendable {
        let usage: CodexUsage
        let availability: Bool
        let unavailableError: Error
        /// Simulates a source that is present but fails mid-fetch (RPC timeout,
        /// malformed response, …) rather than one that reports itself unavailable.
        let fetchError: Error?
        var fetchCount = 0

        init(
            usage: CodexUsage,
            availability: Bool,
            unavailableError: Error = CodexUsageError.noUsageData,
            fetchError: Error? = nil
        ) {
            self.usage = usage
            self.availability = availability
            self.unavailableError = unavailableError
            self.fetchError = fetchError
        }

        func fetchUsage(now _: Date) async throws -> CodexUsage {
            fetchCount += 1
            guard availability else { throw unavailableError }
            if let fetchError { throw fetchError }
            return usage
        }
    }

    private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
        let data: Data
        let status: Int
        var lastRequest: URLRequest?

        init(data: Data, status: Int) {
            self.data = data
            self.status = status
        }

        func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws
            -> (Data, HTTPURLResponse)
        {
            lastRequest = request
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil)!
            return (data, http)
        }
    }
}

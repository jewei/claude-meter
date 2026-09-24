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

    // Repeat process cleanup in one host: waitUntilExit() stalled intermittently
    // after several successful terminations, which a single fixture missed.
    @Test(arguments: 0..<5)
    func appServerTimeoutKillsAndReapsAChildThatIgnoresTerm(iteration _: Int) async throws {
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
            printf '%s' "$$" > "$SHUTDOWN_PID_FILE.tmp"
            /bin/mv "$SHUTDOWN_PID_FILE.tmp" "$SHUTDOWN_PID_FILE"
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
        do {
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
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()
    }

    @Test(arguments: 0..<5)
    func appServerTimeoutRejectsAResponseDuringTerminationGrace(iteration _: Int) async throws {
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
        do {
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
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()
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
        let pidFile = directory.appendingPathComponent("pid")
        let script = """
            #!/bin/sh
            printf '%s' "$$" > "$SHUTDOWN_PID_FILE"
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
            env: [
                "ACCOUNT_MARKER": accountMarker.path, "LIMITS_MARKER": limitsMarker.path,
                "SHUTDOWN_PID_FILE": pidFile.path,
            ],
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
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(pidText))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: limitsMarker.path))
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
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

    @Test func explicitChatGPTModeTakesPrecedenceOverAPIKey() throws {
        let json =
            #"{"auth_mode":"chatgpt","OPENAI_API_KEY":"sk-test","tokens":{"access_token":"access","account_id":"account"}}"#
        let credentials = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(credentials.accessToken == "access")
        #expect(credentials.accountId == "account")
    }

    @Test(arguments: ["apikey", "api_key"])
    func explicitAPIKeyModeRejectsStoredOAuthTokens(mode: String) {
        let json = """
            {"auth_mode":"\(mode)","tokens":{"access_token":"access"}}
            """
        #expect(throws: CodexOAuthCredentialsError.apiKeyOnly) {
            try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        }
    }

    @Test func explicitChatGPTModeWithoutTokensNeedsRecovery() {
        let json = #"{"auth_mode":"chatgpt","OPENAI_API_KEY":"sk-test"}"#
        #expect(throws: CodexOAuthCredentialsError.missingTokens) {
            try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
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

    @Test func directSuccessNeverInvokesAppServer() async throws {
        let appServer = StubCodexSource(usage: Self.usage(source: .appServer), availability: true)
        let oauth = StubCodexSource(usage: Self.usage(source: .directOAuth), availability: true)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)
        for _ in 0..<2 {
            #expect(try await provider.fetchUsage().source == .directOAuth)
        }
        #expect(appServer.fetchCount == 0)
        #expect(oauth.fetchCount == 2)
    }

    @Test(arguments: [
        CodexOAuthCredentialsError.notFound, .missingTokens, .decodeFailed, .unreadable,
        .expiredAccessToken,
    ])
    func credentialFailuresPermitOneRecovery(failure: CodexOAuthCredentialsError) async throws {
        let appServer = StubCodexSource(usage: Self.usage(source: .appServer), availability: true)
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth), availability: true, fetchError: failure)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)
        #expect(try await provider.fetchUsage().source == .appServer)
        #expect(appServer.fetchCount == 1)
        #expect(oauth.fetchCount == 1)
    }

    @Test(arguments: [401, 403, 429, 500, 502, 503])
    func httpFailureClassification(status: Int) async throws {
        let appServer = StubCodexSource(usage: Self.usage(source: .appServer), availability: true)
        let oauth = CodexDirectOAuthSource(
            transport: RecordingTransport(data: Data(), status: status),
            credentialsLoader: {
                CodexOAuthCredentials(accessToken: "opaque", idToken: nil, accountId: nil)
            })
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)
        if status == 401 || status == 403 {
            #expect(try await provider.fetchUsage().source == .appServer)
            #expect(appServer.fetchCount == 1)
        } else {
            await #expect(throws: CodexUsageError.httpError(status)) {
                try await provider.fetchUsage()
            }
            #expect(appServer.fetchCount == 0)
        }
    }

    @Test func otherFailuresNeverStartRecovery() async {
        let failures: [any Error] = [
            URLError(.notConnectedToInternet), URLError(.cannotFindHost), URLError(.timedOut),
            CancellationError(), CodexOAuthCredentialsError.apiKeyOnly, CodexUsageError.noUsageData,
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid usage")),
        ]
        for failure in failures {
            let appServer = StubCodexSource(
                usage: Self.usage(source: .appServer), availability: true)
            let oauth = StubCodexSource(
                usage: Self.usage(source: .directOAuth), availability: true, fetchError: failure)
            let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)
            await #expect(throws: (any Error).self) { try await provider.fetchUsage() }
            #expect(appServer.fetchCount == 0)
        }
    }

    @Test func recoveryFailureRetainsBothErrorsAndCancellation() async {
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth), availability: true,
            fetchError: CodexOAuthCredentialsError.notFound)
        for error in [CodexUsageError.cliNotFound, .rpcFailed("boom")] {
            let recovery = StubCodexSource(
                usage: Self.usage(source: .appServer), availability: true, fetchError: error)
            let provider = CodexUsageProvider(appServerSource: recovery, oauthSource: oauth)
            await #expect(
                throws: CodexUsageError.allSourcesFailed(
                    appServer: error.localizedDescription,
                    directOAuth: CodexOAuthCredentialsError.notFound.localizedDescription)
            ) {
                try await provider.fetchUsage()
            }
            #expect(recovery.fetchCount == 1)
        }
        let cancelled = StubCodexSource(
            usage: Self.usage(source: .appServer), availability: true,
            fetchError: CancellationError())
        await #expect(throws: CancellationError.self) {
            try await CodexUsageProvider(appServerSource: cancelled, oauthSource: oauth)
                .fetchUsage()
        }
    }

    @Test(arguments: [
        "0", "1800000000", "1800000060", "1800000061", "null", "true", "\"expired\"", "1e300", "-1",
    ])
    func jwtExpiryRecovery(exp: String) async throws {
        let payload = Data("{\"exp\":\(exp)}".utf8).base64EncodedString()
        let token = "header.\(payload).signature"
        let transport = RecordingTransport(
            data: Data(#"{"rate_limit":{"primary_window":{"used_percent":12}}}"#.utf8), status: 200)
        let source = CodexDirectOAuthSource(
            transport: transport,
            credentialsLoader: {
                CodexOAuthCredentials(accessToken: token, idToken: nil, accountId: nil)
            })
        let recovery = StubCodexSource(usage: Self.usage(source: .appServer), availability: true)
        let provider = CodexUsageProvider(appServerSource: recovery, oauthSource: source)
        let usage = try await provider.fetchUsage(now: Date(timeIntervalSince1970: 1_800_000_000))
        let expired = ["0", "1800000000", "1800000060"].contains(exp)
        #expect(usage.source == (expired ? .appServer : .directOAuth))
        #expect(recovery.fetchCount == (expired ? 1 : 0))
        #expect((transport.lastRequest == nil) == expired)
    }

    @Test func malformedResetMetadataDoesNotDiscardDirectQuota() throws {
        let json =
            #"{"rate_limit":{"primary_window":{"used_percent":12}},"rate_limit_reset_credits":{"available_count":"bad"}}"#
        let response = try JSONDecoder().decode(CodexOAuthUsageResponse.self, from: Data(json.utf8))
        let usage = try response.usage(accountEmail: nil, now: Date(), source: .directOAuth)
        #expect(usage.primaryWindow?.usedPercent == 12)
        #expect(usage.rateLimitResets == nil)
    }

    @Test func apiKeyRecoveryIsUnavailable() async {
        let recovery = StubCodexSource(
            usage: Self.usage(source: .appServer), availability: true,
            fetchError: CodexOAuthCredentialsError.apiKeyOnly)
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth), availability: true,
            fetchError: CodexOAuthCredentialsError.notFound)
        await #expect(throws: CodexOAuthCredentialsError.apiKeyOnly) {
            try await CodexUsageProvider(appServerSource: recovery, oauthSource: oauth).fetchUsage()
        }
    }

    @Test func malformedOrOversizeJWTExpiryIsUnknown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for token in [
            "opaque", "a.invalid.c", "a.b", "a." + String(repeating: "a", count: 70_000) + ".c",
        ] {
            #expect(!CodexOAuthCredentialsStore.accessTokenNeedsRecovery(token, now: now))
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
              "credits": { "balance": "5" },
              "rate_limit_reset_credits": { "available_count": 0 }
            }
            """
        let transport = RecordingTransport(data: Data(json.utf8), status: 200)
        let source = CodexDirectOAuthSource(
            transport: transport,
            credentialsLoader: {
                CodexOAuthCredentials(
                    accessToken: "access-token",
                    idToken: nil,
                    accountId: "account-id")
            })

        let usage = try await source.fetchUsage(now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(usage.rateLimitResets?.availableCount == 0)
        #expect(usage.rateLimitResets?.credits == nil)
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

    @Test(arguments: [
        ("2027-02-01T00:00:00Z", 1_801_440_000.0),
        ("2027-02-01T00:00:00.123456Z", 1_801_440_000.123456),
    ])
    func directOAuthFetchesResetExpiryWithTheSameCredentials(
        expiry: String, expectedEpoch: TimeInterval
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ResetDetailsTransport {
            let json = Self.resetDetailsJSON.replacingOccurrences(
                of: "2027-02-01T00:00:00.123456Z", with: expiry)
            return (Data(json.utf8), 200)
        }
        let credentials = ResetCredentialsLoader()
        let source = CodexDirectOAuthSource(
            transport: transport, credentialsLoader: { credentials.load() })
        let usage = try await source.fetchUsage(now: now)
        let account = usage.providerAccountSnapshot(id: "test-home", label: "Codex")
        let resets = try #require(account.balances.first { $0.id == "usage-resets" })

        #expect(usage.primaryWindow?.usedPercent == 12)
        #expect(usage.updatedAt == now)
        #expect(usage.source == .directOAuth)
        #expect(resets.value == 3)
        #expect(resets.details?.count == 2)
        #expect(resets.details?.first?.title == "Full reset")
        let expiresAt = try #require(resets.details?.first?.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince1970 - expectedEpoch) < 0.001)
        #expect(resets.details?.last?.expiresAt == nil)
        #expect(credentials.loadCount == 1)

        let requests = await transport.requests
        #expect(
            requests.map { $0.url?.path } == [
                "/backend-api/wham/usage", "/backend-api/wham/rate-limit-reset-credits",
            ])
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-1")
        }
        let detailsRequest = try #require(requests.last)
        #expect(detailsRequest.timeoutInterval == 4)
        #expect(detailsRequest.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(detailsRequest.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
        #expect(detailsRequest.value(forHTTPHeaderField: "originator") == "Codex Desktop")
    }

    @Test(arguments: [401, 403, 404, 429, 500])
    func resetDetailsHTTPFailurePreservesQuotaWithoutRecovery(status: Int) async throws {
        let transport = ResetDetailsTransport { (Data(), status) }
        let recovery = StubCodexSource(usage: Self.usage(source: .appServer), availability: true)
        let provider = CodexUsageProvider(
            appServerSource: recovery, oauthSource: Self.resetDetailsSource(transport))
        let usage = try await provider.fetchUsage()
        #expect(usage.primaryWindow?.usedPercent == 12)
        #expect(usage.rateLimitResets?.availableCount == 3)
        #expect(usage.rateLimitResets?.credits == nil)
        #expect(recovery.fetchCount == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [
        "not JSON", #"{"available_count":3,"credits":"invalid"}"#,
        #"{"available_count":3}"#,
        #"{"available_count":-1,"credits":[]}"#,
        #"{"available_count":2,"credits":[{"status":"available","title":"Other count"}]}"#,
    ])
    func unusableResetDetailsPreserveTheReportedCount(json: String) async throws {
        let transport = ResetDetailsTransport { (Data(json.utf8), 200) }
        let usage = try await Self.resetDetailsSource(transport).fetchUsage()
        #expect(usage.primaryWindow?.usedPercent == 12)
        #expect(usage.rateLimitResets?.availableCount == 3)
        #expect(usage.rateLimitResets?.credits == nil)
    }

    @Test(arguments: [
        "null", "1e308", "{}", "\"invalid\"", "\"3000-01-01T00:00:00Z\"",
        "\"1969-12-31T23:59:59Z\"",
    ])
    func invalidResetExpiryStaysUnknown(expiry: String) async throws {
        let transport = ResetDetailsTransport {
            let json = """
                {"available_count":3,"credits":[
                  {"status":"available","title":"Reset","expires_at":\(expiry)}
                ]}
                """
            return (Data(json.utf8), 200)
        }
        let usage = try await Self.resetDetailsSource(transport).fetchUsage()
        #expect(usage.rateLimitResets?.availableCount == 3)
        #expect(usage.rateLimitResets?.credits?.count == 1)
        #expect(usage.rateLimitResets?.credits?.first?.expiresAt == nil)
        // The accepted reading must remain safe for snapshot persistence.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        _ = try encoder.encode(usage)
    }

    @Test(arguments: ["null", #"{"available_count":0}"#])
    func resetDetailsAreSkippedWithoutAvailableResets(metadata: String) async throws {
        let transport = ResetDetailsTransport(resetMetadata: metadata) {
            Issue.record("Reset details must not be requested")
            return (Data(), 200)
        }
        _ = try await Self.resetDetailsSource(transport).fetchUsage()
        #expect(await transport.requests.count == 1)
    }

    @Test func resetDetailsNetworkFailureClearsEarlierExpiry() async throws {
        let transport = ResetDetailsTransport { (Data(Self.resetDetailsJSON.utf8), 200) }
        let source = Self.resetDetailsSource(transport)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await source.fetchUsage(now: now)
        #expect(first.rateLimitResets?.credits?.count == 2)
        await transport.failDetails()
        let usage = try await source.fetchUsage(now: now.addingTimeInterval(300))
        #expect(usage.primaryWindow?.usedPercent == 12)
        #expect(usage.rateLimitResets?.availableCount == 3)
        #expect(usage.rateLimitResets?.credits == nil)
    }

    @Test func resetDetailsTransportCancellationStopsTheRefresh() async {
        let transport = ResetDetailsTransport { throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await Self.resetDetailsSource(transport).fetchUsage()
        }
    }

    @Test(arguments: [false, true])
    func resetDetailsDeadlineAndCancellationDoNotWaitForTransport(cancel: Bool) async throws {
        let entered = ResetDetailsGate()
        let release = ResetDetailsGate()
        let transport = ResetDetailsTransport {
            entered.signal()
            await release.wait()
            return (Data(Self.resetDetailsJSON.utf8), 200)
        }
        let source = Self.resetDetailsSource(transport, timeout: cancel ? 30 : 0.05)
        let task = Task { try await source.fetchUsage() }
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { release.signal() }
        }
        defer {
            watchdog.cancel()
            release.signal()
            entered.signal()
            task.cancel()
        }
        if cancel {
            try await Timeout.run(seconds: 5) { await entered.wait() }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        } else {
            let usage = try await task.value
            #expect(usage.primaryWindow?.usedPercent == 12)
            #expect(usage.rateLimitResets?.availableCount == 3)
            #expect(usage.rateLimitResets?.credits == nil)
        }
        #expect(!release.isReleased)
    }

    private static let resetDetailsJSON = """
        {"available_count":3,"credits":[
          {"status":"available","title":"Full reset","expires_at":"2027-02-01T00:00:00.123456Z"},
          {"status":"available","title":"No expiry","expires_at":null},
          {"status":"available","title":"Expired","expires_at":"2020-01-01T00:00:00Z"},
          {"status":"available","title":"Expires now","expires_at":"2027-01-15T08:00:00Z"},
          {"status":"redeemed","expires_at":"2028-01-01T00:00:00Z"},
          {"status":"redeeming","expires_at":"2028-01-01T00:00:00Z"},
          {"status":"expired","expires_at":"2028-01-01T00:00:00Z"},
          {"status":"future_status","expires_at":"2028-01-01T00:00:00Z"}
        ]}
        """

    private static func resetDetailsSource(
        _ transport: any HTTPTransport, timeout: TimeInterval = 4
    ) -> CodexDirectOAuthSource {
        CodexDirectOAuthSource(
            transport: transport,
            credentialsLoader: {
                CodexOAuthCredentials(
                    accessToken: "test-token", idToken: nil, accountId: "test-account")
            }, resetCreditsTimeout: timeout)
    }

    private actor ResetDetailsTransport: HTTPTransport {
        let resetMetadata: String
        let details: @Sendable () async throws -> (Data, Int)
        var requests: [URLRequest] = []
        private var detailsFailed = false

        init(
            resetMetadata: String = #"{"available_count":3}"#,
            details: @escaping @Sendable () async throws -> (Data, Int)
        ) {
            self.resetMetadata = resetMetadata
            self.details = details
        }

        func failDetails() { detailsFailed = true }

        func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (
            Data, HTTPURLResponse
        ) {
            requests.append(request)
            #expect(retry.maxRetries == 0)
            let data: Data
            let status: Int
            if request.url?.path == "/backend-api/wham/usage" {
                data = Data(
                    """
                    {"rate_limit":{"primary_window":{"used_percent":12}},
                     "rate_limit_reset_credits":\(resetMetadata)}
                    """.utf8)
                status = 200
            } else {
                if detailsFailed { throw URLError(.notConnectedToInternet) }
                (data, status) = try await details()
            }
            return (
                data,
                HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    private final class ResetCredentialsLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var loadCount: Int { lock.withLock { count } }

        func load() -> CodexOAuthCredentials {
            lock.withLock {
                count += 1
                return CodexOAuthCredentials(
                    accessToken: "token-\(count)", idToken: nil, accountId: "account-\(count)")
            }
        }
    }

    private final class ResetDetailsGate: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        var isReleased: Bool { lock.withLock { released } }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func signal() {
            lock.lock()
            released = true
            let waiter = continuation
            continuation = nil
            lock.unlock()
            waiter?.resume()
        }
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

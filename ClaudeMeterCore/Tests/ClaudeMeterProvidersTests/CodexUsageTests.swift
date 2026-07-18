import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("Codex usage")
struct CodexUsageTests {

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
        let response = try JSONDecoder().decode(CodexAppServerRateLimitsResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_751_000_000)
        let usage = try response.usage(
            account: CodexAppServerAccount(email: "alpha@example.com", plan: nil, authMode: .chatGPT),
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

    @Test func cardDisplayPercentUsesUsedPercentLikeCursor() {
        let window = CodexLimitWindow(
            kind: .primary,
            usedPercent: 82,
            resetAt: nil,
            durationSeconds: 18_000,
            rawLabel: nil)

        #expect(window.cardDisplayPercent == 82)
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
        #expect(appServer.fetchCount == 0)
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

    @Test func providerKeepsMostUsefulFailureWhenBothSourcesUnavailable() async {
        let appServer = StubCodexSource(
            usage: Self.usage(source: .appServer),
            availability: false,
            unavailableError: CodexUsageError.cliNotFound)
        let oauth = StubCodexSource(
            usage: Self.usage(source: .directOAuth),
            availability: false,
            unavailableError: CodexOAuthCredentialsError.notFound)
        let provider = CodexUsageProvider(appServerSource: appServer, oauthSource: oauth)

        await #expect(throws: CodexUsageError.cliNotFound) {
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
        let response = try JSONDecoder().decode(CodexAppServerAccountResponse.self, from: Data(json.utf8))

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
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

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
        #expect(usage.primaryWindow?.usedPercent == 12)
        #expect(transport.lastRequest?.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-id")
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
        var fetchCount = 0

        init(
            usage: CodexUsage,
            availability: Bool,
            unavailableError: Error = CodexUsageError.noUsageData)
        {
            self.usage = usage
            self.availability = availability
            self.unavailableError = unavailableError
        }

        func isAvailable() async -> Bool {
            availability
        }

        func fetchUsage(now _: Date) async throws -> CodexUsage {
            fetchCount += 1
            guard availability else { throw unavailableError }
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

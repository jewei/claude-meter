import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

extension OAuthPipelineTests {
    @Test func credentialServiceMustMatchTheConfigAccount() {
        let work = AccountConfig(
            id: "claude-work", label: "work",
            configDir: URL(fileURLWithPath: "/tmp/claude-meter-identity/.claude-work"))
        let service = OAuthKeychain.credentialServices(
            forConfigDirPath: work.configDir.path, isDefault: false)[0]

        #expect(
            OAuthKeychain.accountKey(forCredentialService: service, accounts: [work]) == work.id)
        #expect(OAuthKeychain.accountKey(forCredentialService: service, accounts: []) == nil)
        #expect(OAuthKeychain.accountKey(forCredentialService: nil, accounts: [work]) == nil)
        #expect(
            OAuthKeychain.accountKey(
                forCredentialService: "Claude Code-credentials", accounts: [work]) == "claude")
    }

    @Test func unknownAutomaticLoginDoesNotUseTheDefaultAccountKey() {
        let service = "Claude Code-credentials-01234567"
        let key = OAuthPipeline.sourceAccountKey(
            credentialService: service, isManual: false, accounts: [])

        #expect(key != "claude")
        #expect(key.hasPrefix("oauth-"))
        #expect(
            key
                != OAuthPipeline.sourceAccountKey(
                    credentialService: "Claude Code-credentials-76543210",
                    isManual: false, accounts: []))
        #expect(
            OAuthPipeline.sourceAccountKey(
                credentialService: nil, isManual: true, accounts: []) == "claude")
    }

    @Test func refreshRetainsTheSelectedCredentialAccount() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: MeterSettings.oauthModeKey)
        defaults.set("auto", forKey: MeterSettings.oauthModeKey)
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        OAuthRefreshGate.resetForTesting()
        OAuthRefreshCoordinator.resetForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let work = AccountConfig(
            id: "claude-work", label: "work", configDir: root.appendingPathComponent(".claude-work")
        )
        let service = OAuthKeychain.credentialServices(
            forConfigDirPath: work.configDir.path, isDefault: false)[0]
        let source = OAuthCredentials(
            accessToken: "expired-access", refreshToken: "source-refresh",
            expiresAt: .distantPast, subscriptionType: "max", credentialService: service)
        let transport = SourceIdentityTransport()
        OAuthPipeline.setAutomaticCredentialLoaderForTesting { .found(source) }
        OAuthPipeline.setTransportForTesting(transport)
        defer {
            OAuthPipeline.setAutomaticCredentialLoaderForTesting(nil)
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            OAuthPipeline.clearRateLimitForTesting()
            OAuthRefreshGate.resetForTesting()
            OAuthRefreshCoordinator.resetForTesting()
            if let previousMode {
                defaults.set(previousMode, forKey: MeterSettings.oauthModeKey)
            } else {
                defaults.removeObject(forKey: MeterSettings.oauthModeKey)
            }
            try? FileManager.default.removeItem(at: root)
        }
        let pipeline = OAuthPipeline(
            fallback: IdentityFallbackPipeline(),
            accountConfigs: { [work] })

        let snapshot = try #require(try await pipeline.poll(now: Date()).snapshot)
        #expect(snapshot.accounts?.first?.id == work.id)
        #expect(snapshot.accounts?.count == 1)
        #expect(snapshot.accounts?.first?.limits == snapshot.limits)
        #expect(
            OAuthPipeline.credentials(
                from: .temporarilyUnavailable, oauthMode: "auto")?.credentialService == service)
        #expect(snapshot.limits.currentWeekOpus?.percentUsed == 90)
        #expect(await transport.refreshCount == 1)
        #expect(await transport.usageCount == 1)
    }
}

private struct IdentityFallbackPipeline: ClaudeMeterPipeline {
    func poll(now: Date, kind: RefreshKind) async throws -> ParseResult {
        ParseResult(snapshot: nil, warnings: [], errors: [], parserVersion: "test")
    }
}

private actor SourceIdentityTransport: HTTPTransport {
    private(set) var refreshCount = 0
    private(set) var usageCount = 0

    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (Data, HTTPURLResponse)
    {
        let body: String
        if request.httpMethod == "POST" {
            refreshCount += 1
            body =
                #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}"#
        } else {
            usageCount += 1
            #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
            body =
                #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"seven_day_opus":{"utilization":90}}"#
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

extension OAuthPipelineTests {
    @MainActor
    @Test(arguments: [false, true])
    func oauthFailureUsesOnlyLastGoodData(hasPrevious: Bool) async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: MeterSettings.oauthModeKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defaults.set("auto", forKey: MeterSettings.oauthModeKey)
        OAuthPipeline.clearCachedCredentials()
        OAuthPipeline.clearRateLimitForTesting()
        let transport = OfflineUsageTransport()
        OAuthPipeline.setTransportForTesting(transport)
        OAuthPipeline.setAutomaticCredentialLoaderForTesting {
            .found(
                OAuthCredentials(
                    accessToken: "test-access", refreshToken: "test-refresh",
                    expiresAt: .distantFuture, credentialService: "Claude Code-credentials"))
        }
        defer {
            OAuthPipeline.setTransportForTesting(nil)
            OAuthPipeline.setAutomaticCredentialLoaderForTesting(nil)
            OAuthPipeline.clearCachedCredentials()
            defaults.set(previousMode, forKey: MeterSettings.oauthModeKey)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SnapshotStore(directory: directory)
        let observed = Date().addingTimeInterval(-100)
        if hasPrevious {
            try store.writeLatest(
                ClaudeUsageSnapshot(
                    parserVersion: "oauth-api-1.0", createdAt: observed,
                    lastSuccessfulPollAt: observed,
                    source: SourceInfo(
                        cliPath: "api.anthropic.com", command: "GET /api/oauth/usage"),
                    limits: LimitInfo(currentSession: LimitWindow(percentUsed: 37)),
                    state: SnapshotState(status: .ok, severity: .normal)))
        }
        let provider = ClaudeProviderAdapter(
            configuration: { .init(mode: "auto") }, directory: directory,
            discover: { _ in [] }, secondary: { _, _, _ in [] })
        let id = UUID()
        let now = Date()
        let previous = try await provider.validatePrevious(nil, now: now, refreshID: id)
        let result = try await provider.fetch(now: now, previous: previous, refreshID: id)
        provider.didAccept(result, refreshID: id)
        await provider.waitForPersistence()
        #expect(provider.diagnostics.sourceAttempts.first?.reason == .networkError)
        if hasPrevious {
            #expect(result.accounts.first?.windows.first?.usedPercent == 37)
            #expect(result.accounts.first?.isStale == true)
            #expect(abs(result.accounts[0].observedAt!.timeIntervalSince(observed)) < 1)
        } else {
            #expect(result.accounts.first?.observedAt == nil)
        }
        #expect(await transport.urls == ["https://api.anthropic.com/api/oauth/usage"])
    }
}

private actor OfflineUsageTransport: HTTPTransport {
    var urls: [String] = []
    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (Data, HTTPURLResponse)
    {
        urls.append(request.url!.absoluteString)
        throw URLError(.notConnectedToInternet)
    }
}

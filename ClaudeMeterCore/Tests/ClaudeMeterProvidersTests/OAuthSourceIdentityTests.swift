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

    @Test func refreshAndEnrichmentRetainTheSelectedCredentialAccount() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppGroupConfig.oauthModeKey)
        defaults.set("auto", forKey: AppGroupConfig.oauthModeKey)
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
                defaults.set(previousMode, forKey: AppGroupConfig.oauthModeKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.oauthModeKey)
            }
            try? FileManager.default.removeItem(at: root)
        }
        let pipeline = OAuthPipeline(
            fallback: IdentityFallbackPipeline(), store: SnapshotStore(directory: root),
            accountConfigs: { [work] })

        let snapshot = try #require(try await pipeline.poll(now: Date()).snapshot)
        #expect(snapshot.activeAccountID == work.id)
        #expect(snapshot.accounts?.count == 1)
        #expect(snapshot.accounts?.first?.limits == snapshot.limits)
        #expect(
            OAuthPipeline.credentials(
                from: .temporarilyUnavailable, oauthMode: "auto")?.credentialService == service)
        guard case .success(let enrichment) = await OAuthPipeline.fetchEnrichmentResult() else {
            Issue.record("Expected enrichment from the refreshed automatic credential")
            return
        }
        #expect(enrichment.credentialService == service)
        #expect(enrichment.opus?.percentUsed == 90)
        #expect(await transport.refreshCount == 1)
    }
}

private struct IdentityFallbackPipeline: ClaudeMeterPipeline {
    func poll(now: Date, kind: RefreshKind) async throws -> ParseResult {
        ParseResult(snapshot: nil, warnings: [], errors: [], rawHash: "", parserVersion: "test")
    }
}

private actor SourceIdentityTransport: HTTPTransport {
    private(set) var refreshCount = 0

    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (Data, HTTPURLResponse)
    {
        let body: String
        if request.httpMethod == "POST" {
            refreshCount += 1
            body =
                #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}"#
        } else {
            body =
                #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"seven_day_opus":{"utilization":90}}"#
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

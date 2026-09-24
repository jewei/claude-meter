import ClaudeMeterCore
import Foundation
import Testing

@testable import ClaudeMeterProviders

private struct AdapterTransport: HTTPTransport {
    var status = 200
    var cancelled = false

    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (Data, HTTPURLResponse)
    {
        if cancelled { throw CancellationError() }
        let url = request.url!
        let json: String
        if url.host == "cli-chat-proxy.grok.com" {
            json =
                #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"},"creditUsagePercent":42}}"#
        } else if url.path.hasSuffix("GetPlanInfo") {
            json = #"{"planInfo":{"planName":"pro"}}"#
        } else {
            json = #"{"planUsage":{"totalPercentUsed":25},"enabled":true}"#
        }
        return (
            Data(json.utf8),
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

struct UsageProviderAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [ProviderID.cursor, .grok], [false, true])
    @MainActor
    func accountSwitchCannotRetainPreviousUsage(id: ProviderID, switchAfterValidation: Bool)
        async throws
    {
        let source = AdapterCredentialSource()
        let transport = ChangingAdapterTransport()
        let provider = sourcedProvider(id, source: source, transport: transport)
        let firstID = UUID()
        _ = try await provider.validatePrevious(nil, now: now, refreshID: firstID)
        let first = try await provider.fetch(now: now, previous: nil, refreshID: firstID)
        provider.didAccept(first, refreshID: firstID)
        if !switchAfterValidation { source.token = "account-b" }
        let secondID = UUID()
        let previous = try await provider.validatePrevious(first, now: now, refreshID: secondID)
        #expect(previous == (switchAfterValidation ? first : nil))
        source.token = "account-b"
        transport.status = 500
        do {
            _ = try await provider.fetch(now: now, previous: previous, refreshID: secondID)
            Issue.record("Expected network failure")
        } catch let failure as UsageProviderFailure {
            if switchAfterValidation { #expect(!failure.retainsLastGood) }
        }
    }

    private func sourcedProvider(
        _ id: ProviderID, source: AdapterCredentialSource, transport: ChangingAdapterTransport
    ) -> any UsageProvider {
        if id == .cursor {
            return CursorProviderAdapter(
                provider: CursorUsageProvider(
                    transport: transport,
                    credentialsLoader: {
                        CursorCredentials(
                            accessToken: source.token, refreshToken: nil, email: nil,
                            membership: "pro")
                    }))
        } else {
            return GrokProviderAdapter(
                provider: GrokUsageProvider(
                    transport: transport,
                    credentialsLoader: { _ in
                        GrokCredentials(bearer: source.token, email: nil, expiresAt: nil)
                    }))
        }
    }

    @Test(arguments: [ProviderID.cursor, .grok], [200, 500])
    @MainActor
    func accountSwitchDuringRequestRejectsOldResponse(id: ProviderID, status: Int) async throws {
        let source = AdapterCredentialSource()
        let transport = ChangingAdapterTransport()
        let provider = sourcedProvider(id, source: source, transport: transport)
        let firstID = UUID()
        _ = try await provider.validatePrevious(nil, now: now, refreshID: firstID)
        let first = try await provider.fetch(now: now, previous: nil, refreshID: firstID)
        provider.didAccept(first, refreshID: firstID)
        let secondID = UUID()
        let previous = try await provider.validatePrevious(first, now: now, refreshID: secondID)
        #expect(previous == first)
        transport.status = status
        transport.onRequest = { source.token = "account-b" }
        do {
            _ = try await provider.fetch(now: now, previous: previous, refreshID: secondID)
            Issue.record("An old login supplied a response after the credential changed")
        } catch let failure as UsageProviderFailure {
            #expect(!failure.retainsLastGood)
        }
    }

    @Test(arguments: [ProviderID.cursor, .grok])
    @MainActor
    func sameCredentialNetworkFailureRetainsAcceptedUsage(id: ProviderID) async throws {
        let source = AdapterCredentialSource()
        let transport = ChangingAdapterTransport()
        let provider = sourcedProvider(id, source: source, transport: transport)
        let firstID = UUID()
        _ = try await provider.validatePrevious(nil, now: now, refreshID: firstID)
        let first = try await provider.fetch(now: now, previous: nil, refreshID: firstID)
        provider.didAccept(first, refreshID: firstID)
        let secondID = UUID()
        let previous = try await provider.validatePrevious(first, now: now, refreshID: secondID)
        #expect(previous == first)
        transport.status = 500
        do {
            _ = try await provider.fetch(now: now, previous: previous, refreshID: secondID)
            Issue.record("Expected server failure")
        } catch let failure as UsageProviderFailure {
            #expect(failure.retainsLastGood)
        }
    }

    private func cursor(transport: AdapterTransport) -> CursorProviderAdapter {
        CursorProviderAdapter(
            provider: CursorUsageProvider(
                transport: transport,
                credentialsLoader: {
                    CursorCredentials(
                        accessToken: "test-access", refreshToken: nil, email: nil, membership: nil)
                }))
    }

    private func grok(transport: AdapterTransport) -> GrokProviderAdapter {
        GrokProviderAdapter(
            provider: GrokUsageProvider(
                transport: transport,
                credentialsLoader: { _ in
                    GrokCredentials(bearer: "test-access", email: nil, expiresAt: nil)
                }))
    }

    @Test("Both fetch adapters return normalized current observations")
    func fetchContract() async throws {
        let providers: [any UsageProvider] = [
            cursor(transport: AdapterTransport()), grok(transport: AdapterTransport()),
        ]
        for provider in providers {
            let result = try await provider.fetch(
                now: now, previous: nil, refreshID: UUID()
            )
            #expect(result.provider == provider.id)
            #expect(result.fetchedAt == now)
            #expect(result.accounts.count == 1)
            #expect(result.accounts[0].observedAt == now)
            #expect(!result.accounts[0].isStale)
            #expect(result.accounts[0].windows[0].usedPercent == (provider.id == .cursor ? 25 : 42))
        }
    }

    @Test("Cursor and Grok retain accepted usage only for the same credentials")
    @MainActor
    func defaultLifecycle() async throws {
        let providers: [any UsageProvider] = [
            cursor(transport: AdapterTransport()), grok(transport: AdapterTransport()),
        ]
        for provider in providers {
            let id = UUID()
            #expect(try await provider.validatePrevious(nil, now: now, refreshID: id) == nil)
            let snapshot = try await provider.fetch(now: now, previous: nil, refreshID: id)
            provider.didAccept(snapshot, refreshID: id)
            let previous = try await provider.validatePrevious(
                snapshot, now: now, refreshID: UUID())
            #expect(previous == snapshot)
            await provider.waitForPersistence()
            #expect(!provider.ownsDeadline)
        }
    }

    @Test(
        "Cursor rejection discards old data; temporary errors retain it",
        arguments: [401, 403, 500])
    func cursorFailures(_ status: Int) async {
        do {
            _ = try await cursor(transport: AdapterTransport(status: status)).fetch(now: now)
            Issue.record("Expected a neutral failure")
        } catch let failure as UsageProviderFailure {
            #expect(failure.retainsLastGood == (status == 500))
            #expect(!failure.message.isEmpty)
        } catch { Issue.record("Provider error escaped the adapter: \(error)") }
    }

    @Test("Missing Cursor credentials cannot retain another login's usage")
    func cursorMissingCredentials() async {
        let adapter = CursorProviderAdapter(
            provider: CursorUsageProvider(
                transport: AdapterTransport(), credentialsLoader: { nil }))
        do {
            _ = try await adapter.fetch(now: now)
            Issue.record("Expected missing credentials")
        } catch let failure as UsageProviderFailure {
            #expect(!failure.retainsLastGood)
        } catch { Issue.record("Provider error escaped the adapter: \(error)") }
    }

    @Test("Grok errors keep its existing last-good policy", arguments: [401, 500])
    func grokFailures(_ status: Int) async {
        do {
            _ = try await grok(transport: AdapterTransport(status: status)).fetch(now: now)
            Issue.record("Expected a neutral failure")
        } catch let failure as UsageProviderFailure {
            #expect(failure.retainsLastGood)
        } catch { Issue.record("Provider error escaped the adapter: \(error)") }
    }

    @Test("Adapters keep cancellation distinct from failure")
    func cancellation() async {
        let providers: [any UsageProvider] = [
            cursor(transport: AdapterTransport(cancelled: true)),
            grok(transport: AdapterTransport(cancelled: true)),
        ]
        for provider in providers {
            do {
                _ = try await provider.fetch(now: now, previous: nil, refreshID: UUID())
                Issue.record("Expected cancellation")
            } catch is CancellationError {
            } catch { Issue.record("Cancellation became a failure: \(error)") }
        }
    }

    @Test("Neutral failures redact secret values")
    func failureSanitization() {
        struct SecretFailure: LocalizedError {
            var errorDescription: String? { "Bearer secret-token for person@example.com" }
        }
        let failure = UsageProviderFailure(SecretFailure())
        #expect(!failure.message.contains("secret-token"))
        #expect(!failure.message.contains("person@example.com"))
    }
}

private final class AdapterCredentialSource: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = "account-a"
    var token: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ChangingAdapterTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus = 200
    private var action: (@Sendable () -> Void)?
    var onRequest: (@Sendable () -> Void)? {
        get { lock.withLock { action } }
        set { lock.withLock { action = newValue } }
    }
    var status: Int {
        get { lock.withLock { storedStatus } }
        set { lock.withLock { storedStatus = newValue } }
    }
    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (Data, HTTPURLResponse)
    {
        onRequest?()
        return try await AdapterTransport(status: status).send(request, retry: retry)
    }
}

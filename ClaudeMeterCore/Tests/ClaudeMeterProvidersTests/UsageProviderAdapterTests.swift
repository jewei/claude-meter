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

    @Test("Cursor and Grok use unchanged previous state and no-op commit defaults")
    @MainActor
    func defaultLifecycle() async throws {
        let providers: [any UsageProvider] = [
            cursor(transport: AdapterTransport()), grok(transport: AdapterTransport()),
        ]
        for provider in providers {
            let id = UUID()
            #expect(try await provider.validatePrevious(nil, now: now, refreshID: id) == nil)
            let snapshot = try await provider.fetch(now: now, previous: nil, refreshID: id)
            let previous = try await provider.validatePrevious(
                snapshot, now: now, refreshID: UUID())
            #expect(previous == snapshot)
            provider.didAccept(snapshot, refreshID: id)
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

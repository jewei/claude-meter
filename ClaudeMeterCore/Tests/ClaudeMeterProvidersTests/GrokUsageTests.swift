import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("Grok usage")
struct GrokUsageTests {

    /// Live fixture captured 2026-07-11 from cli-chat-proxy.grok.com (grok 0.2.93).
    static let liveFixture = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-04T05:57:34.172321+00:00","end":"2026-07-11T05:57:34.172321+00:00"},"creditUsagePercent":36.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":36.0}],"isUnifiedBillingUser":true,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-07-04T05:57:34.172321+00:00","billingPeriodEnd":"2026-07-11T05:57:34.172321+00:00"}}
        """

    @Test func decodesLiveBillingFixture() throws {
        let response = try JSONDecoder().decode(
            GrokBillingResponse.self, from: Data(Self.liveFixture.utf8))
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let usage = try response.usage(accountEmail: "alpha@example.com", now: now)

        #expect(usage.usedPercent == 36.0)
        #expect(usage.energyLeftPercent == 64.0)
        #expect(usage.windowLabel == "Weekly")
        #expect(usage.onDemandUsedCents == 0)
        #expect(usage.prepaidBalanceCents == 0)
        #expect(usage.maskedAccountEmail == "a***@example.com")
        // 2026-07-11T05:57:34Z (fraction stripped, second precision).
        #expect(usage.resetsAt == Date(timeIntervalSince1970: 1_783_749_454))
        #expect(usage.updatedAt == now)
    }

    /// Proto3 omits zero-valued fields: no creditUsagePercent + present period = 0% used.
    @Test func absentPercentWithPresentPeriodMeansZeroUsed() throws {
        let json = """
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-04T05:57:34.172321+00:00","end":"2026-07-11T05:57:34.172321+00:00"},"onDemandCap":{"val":0},"isUnifiedBillingUser":true}}
            """
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: Data(json.utf8))
        let usage = try response.usage(accountEmail: nil, now: Date(timeIntervalSince1970: 0))

        #expect(usage.usedPercent == 0)
        #expect(usage.energyLeftPercent == 100)
    }

    @Test func missingPeriodThrowsMalformed() throws {
        let response = try JSONDecoder().decode(
            GrokBillingResponse.self, from: Data(#"{"config":{}}"#.utf8))
        #expect(throws: GrokUsageError.malformedResponse) {
            try response.usage(accountEmail: nil, now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func mapsOnDemandMinorUnits() throws {
        let json = """
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-07-01T00:00:00+00:00","end":"2026-08-01T00:00:00+00:00"},"creditUsagePercent":12.5,"onDemandCap":{"val":1000},"onDemandUsed":{"val":42},"prepaidBalance":{"val":250}}}
            """
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: Data(json.utf8))
        let usage = try response.usage(accountEmail: nil, now: Date(timeIntervalSince1970: 0))

        #expect(usage.windowLabel == "Monthly")
        #expect(usage.onDemandUsedCents == 42)
        #expect(usage.onDemandCapCents == 1000)
        #expect(usage.prepaidBalanceCents == 250)
    }

    @Test func parsesMicrosecondAndPlainTimestamps() {
        // Microsecond fraction (ISO8601DateFormatter.withFractionalSeconds rejects >3 digits).
        #expect(
            GrokTimestamp.parse("2026-07-04T05:57:34.172321+00:00")
                == Date(timeIntervalSince1970: 1_783_144_654))
        #expect(
            GrokTimestamp.parse("2026-07-04T05:57:34Z")
                == Date(timeIntervalSince1970: 1_783_144_654))
        #expect(GrokTimestamp.parse("not-a-date") == nil)
    }

    @Test func percentClampsForDisplay() {
        let usage = GrokUsage(
            usedPercent: 120, windowLabel: "Weekly", periodStart: nil, resetsAt: nil,
            onDemandUsedCents: 0, onDemandCapCents: 0, prepaidBalanceCents: 0,
            accountEmail: nil, updatedAt: Date(timeIntervalSince1970: 0))
        #expect(usage.energyLeftPercent == 0)
        #expect(usage.cardDisplayPercent == 100)
    }

    @Test func providerSendsBearerAndDecodesUsage() async throws {
        let transport = RecordingGrokTransport(data: Data(Self.liveFixture.utf8), status: 200)
        let provider = GrokUsageProvider(
            transport: transport,
            credentialsLoader: { _ in
                GrokCredentials(bearer: "bearer-token", email: "alpha@example.com", expiresAt: nil)
            })
        let usage = try await provider.fetchUsage(now: Date(timeIntervalSince1970: 1_783_000_000))

        #expect(usage.usedPercent == 36.0)
        #expect(usage.accountEmail == "alpha@example.com")
        #expect(
            transport.lastRequest?.url?.absoluteString
                == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(
            transport.lastRequest?.value(forHTTPHeaderField: "Authorization")
                == "Bearer bearer-token")
    }

    @Test func providerMapsUnauthorizedToLoginRequired() async {
        let transport = RecordingGrokTransport(data: Data(), status: 401)
        let provider = GrokUsageProvider(
            transport: transport,
            credentialsLoader: { _ in GrokCredentials(bearer: "t", email: nil, expiresAt: nil) })
        await #expect(throws: GrokUsageError.loginRequired) {
            try await provider.fetchUsage(now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func providerMapsServerErrorToHTTPError() async {
        let transport = RecordingGrokTransport(data: Data(), status: 503)
        let provider = GrokUsageProvider(
            transport: transport,
            credentialsLoader: { _ in GrokCredentials(bearer: "t", email: nil, expiresAt: nil) })
        await #expect(throws: GrokUsageError.httpError(503)) {
            try await provider.fetchUsage(now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func providerPropagatesCredentialFailureWithoutNetwork() async {
        let transport = RecordingGrokTransport(data: Data(), status: 200)
        let provider = GrokUsageProvider(
            transport: transport,
            credentialsLoader: { _ in throw GrokAuthError.loginRequired })
        await #expect(throws: GrokAuthError.loginRequired) {
            try await provider.fetchUsage(now: Date(timeIntervalSince1970: 0))
        }
        #expect(transport.lastRequest == nil)
    }
}

private final class RecordingGrokTransport: HTTPTransport, @unchecked Sendable {
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
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

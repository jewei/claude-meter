import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("Cursor usage")
struct CursorUsageTests {
    @Test(arguments: [true, false])
    func externalCredentialsNeverRotate(expired: Bool) async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = Self.makeJWT(
            exp: now.addingTimeInterval(expired ? -1 : 30).timeIntervalSince1970)
        let transport = CursorProactiveRejectionTransport(usageStatus: 401)
        let provider = CursorUsageProvider(
            transport: transport,
            credentialsLoader: {
                CursorCredentials(
                    accessToken: token, refreshToken: "owner-refresh", email: nil, membership: "pro"
                )
            })
        await #expect(throws: CursorError.unauthorized) { try await provider.fetchUsage(now: now) }
        #expect(await transport.refreshTokens.isEmpty)
        #expect(await transport.authorizationHeaders.count == (expired ? 0 : 1))
    }

    @Test func decodesAndNormalizesPlanUsage() throws {
        let json = """
            {
              "billingCycleStart": "1750000000000",
              "billingCycleEnd": "1752592200000",
              "planUsage": {
                "totalSpend": 1240,
                "limit": 2000,
                "autoPercentUsed": 10.0,
                "apiPercentUsed": 100.0,
                "totalPercentUsed": 62.0
              },
              "enabled": true
            }
            """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_751_000_000)
        let usage = response.usage(planName: "pro", email: "x@y.z", now: now)

        #expect(usage.percentUsed == 62.0)
        #expect(usage.autoPercentUsed == 10.0)
        #expect(usage.apiPercentUsed == 100.0)
        #expect(usage.spendUsd == 12.40)
        #expect(usage.limitUsd == 20.00)
        #expect(usage.periodEnd == Date(timeIntervalSince1970: 1_752_592_200))
        #expect(usage.spendText == "$12.40")
        #expect(usage.planName == "pro")
        #expect(usage.displayPlanName == "Pro")
    }

    @Test func zeroLimitMeansNoFixedLimit() throws {
        let json = """
            { "planUsage": { "totalSpend": 500, "limit": 0, "totalPercentUsed": 0 }, "enabled": true }
            """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(json.utf8))
        let usage = response.usage(planName: nil, email: nil, now: Date())
        #expect(usage.limitUsd == nil)
        #expect(usage.spendText == "$5.00")
    }

    @Test func optionalBreakdownStaysMissingForOlderResponses() throws {
        let json = """
            { "planUsage": { "totalPercentUsed": 22 }, "enabled": true }
            """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(json.utf8))
        let usage = response.usage(planName: "pro_plus", email: nil, now: Date())

        #expect(usage.percentUsed == 22)
        #expect(usage.autoPercentUsed == nil)
        #expect(usage.apiPercentUsed == nil)
        #expect(usage.displayPlanName == "Pro+")
    }

    @Test func displayPercentagesRespectProgressionMode() {
        let usage = CursorUsage(
            percentUsed: 0,
            autoPercentUsed: 25,
            apiPercentUsed: 100)

        #expect(usage.displayPercent(showUsage: true) == 0)
        #expect(usage.displayPercent(showUsage: false) == 100)
        #expect(usage.displayAutoPercent(showUsage: false) == 75)
        #expect(usage.displayAPIPercent(showUsage: false) == 0)
        #expect(CursorUsage().displayPercent(showUsage: false) == nil)
    }

    @Test func clampsBreakdownPercentagesForDisplay() {
        let usage = CursorUsage(
            percentUsed: 101,
            autoPercentUsed: -1,
            apiPercentUsed: 103,
            planName: "  Custom Plan  ")

        #expect(usage.clampedPercent == 100)
        #expect(usage.clampedAutoPercent == 0)
        #expect(usage.clampedAPIPercent == 100)
        #expect(usage.displayPlanName == "Custom Plan")
    }

    @Test func parsesDateFromMillisSecondsAndISO() {
        #expect(
            parseEpochOrISODate("1752592200000")
                == Date(timeIntervalSince1970: 1_752_592_200))
        #expect(
            parseEpochOrISODate("1752592200")
                == Date(timeIntervalSince1970: 1_752_592_200))
        #expect(parseEpochOrISODate("2025-07-15T14:30:00Z") != nil)
        #expect(parseEpochOrISODate("nan") == nil)
        #expect(parseEpochOrISODate("inf") == nil)
        #expect(parseEpochOrISODate("-inf") == nil)
        #expect(parseEpochOrISODate("1e309") == nil)
        #expect(parseEpochOrISODate("1e308") == nil)
        #expect(parseEpochOrISODate("32503680000") == nil)
        #expect(parseEpochOrISODate("-1") == nil)
        #expect(parseEpochOrISODate("") == nil)
        #expect(parseEpochOrISODate(nil) == nil)
    }

    @Test func decodesJWTExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = Self.makeJWT(exp: now.addingTimeInterval(3600).timeIntervalSince1970)
        let exp = CursorTokenStore.expiry(of: token)
        #expect(exp == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(CursorTokenStore.isExpiringSoon(token, buffer: 300, now: now) == false)
        #expect(
            CursorTokenStore.isExpiringSoon(token, buffer: 300, now: now.addingTimeInterval(3500)))
    }

    @Test func opaqueTokenHasUnknownExpiry() {
        #expect(CursorTokenStore.expiry(of: "not-a-jwt") == nil)
    }

    @Test func unquotesJsonStoredValues() {
        #expect(CursorTokenStore.unquoteStoredValue("\"token-value\"") == "token-value")
        #expect(CursorTokenStore.unquoteStoredValue("plain") == "plain")
    }

    @Test func disabledUsageThrows() throws {
        let json = """
            { "planUsage": { "totalSpend": 0, "limit": 0, "totalPercentUsed": 0 }, "enabled": false }
            """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(json.utf8))
        #expect(throws: CursorError.usageDisabled) {
            try response.validatedUsage(planName: nil, email: nil, now: Date())
        }
    }

    @Test func switchingDetectedAccountUsesCurrentAccessToken() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let firstToken = Self.makeJWT(exp: now.addingTimeInterval(3600).timeIntervalSince1970)
        let secondToken = Self.makeJWT(exp: now.addingTimeInterval(7200).timeIntervalSince1970)
        let credentials = MutableCursorCredentialSource(
            CursorCredentials(
                accessToken: firstToken, refreshToken: nil,
                email: "first@example.com", membership: "pro"))
        let transport = RecordingCursorTransport()
        let provider = CursorUsageProvider(
            transport: transport, credentialsLoader: { credentials.value })

        _ = try await provider.fetchUsage(now: now)
        credentials.value = CursorCredentials(
            accessToken: secondToken, refreshToken: nil,
            email: "second@example.com", membership: "pro")
        let second = try await provider.fetchUsage(now: now)

        #expect(
            transport.authorizationHeaders == ["Bearer \(firstToken)", "Bearer \(secondToken)"])
        #expect(second.email == "second@example.com")
    }

    @Test func completedRefreshHandoffsStayIndependentAcrossKeys() async throws {
        let coordinator = RefreshResultHandoffCoordinator<String, String>(
            maximumCompletedHandoffs: 8)
        let calls = CursorRefreshCallCounts()

        func request(_ key: String) async throws -> String {
            try await coordinator.run(key: key) {
                await calls.perform(key)
            }
        }

        #expect(try await request("account-a") == "result-account-a")
        #expect(try await request("account-b") == "result-account-b")
        #expect(try await request("account-a") == "result-account-a")
        #expect(try await request("account-b") == "result-account-b")
        #expect(await calls.count(for: "account-a") == 1)
        #expect(await calls.count(for: "account-b") == 1)

        coordinator.adopted(key: "account-a")
        #expect(try await request("account-a") == "result-account-a")
        #expect(try await request("account-b") == "result-account-b")
        #expect(await calls.count(for: "account-a") == 1)
        #expect(await calls.count(for: "account-b") == 1)

        #expect(
            try await request("account-a-next-generation")
                == "result-account-a-next-generation")
        #expect(await calls.count(for: "account-a-next-generation") == 1)
    }

    // MARK: - Helpers

    private static func makeJWT(exp: TimeInterval) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": exp])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}

private actor CursorRefreshCallCounts {
    private var counts: [String: Int] = [:]

    func perform(_ key: String) -> String {
        counts[key, default: 0] += 1
        return "result-\(key)"
    }

    func count(for key: String) -> Int {
        counts[key, default: 0]
    }
}

private final class MutableCursorCredentialSource: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CursorCredentials
    private var reads = 0
    init(_ value: CursorCredentials) { self.stored = value }
    var value: CursorCredentials {
        get {
            lock.withLock {
                reads += 1
                return stored
            }
        }
        set { lock.withLock { stored = newValue } }
    }
    var readCount: Int { lock.withLock { reads } }
}

private final class RecordingCursorTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String] = []
    var authorizationHeaders: [String] { lock.withLock { headers } }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        if let value = request.value(forHTTPHeaderField: "Authorization") {
            lock.withLock { headers.append(value) }
        }
        let data = Data(
            #"{"planUsage":{"totalSpend":0,"limit":100,"totalPercentUsed":0},"enabled":true}"#.utf8)
        return (
            data,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

private actor CursorProactiveRejectionTransport: HTTPTransport {
    private let usageStatus: Int
    private(set) var refreshTokens: [String] = []
    private(set) var authorizationHeaders: [String] = []

    init(usageStatus: Int = 200) {
        self.usageStatus = usageStatus
    }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        if request.url?.path == "/oauth/token" {
            let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            let body = object as? [String: String]
            refreshTokens.append(body?["refresh_token"] ?? "")
            return response(status: 401, body: "{}", request: request)
        }

        authorizationHeaders.append(
            request.value(forHTTPHeaderField: "Authorization") ?? "")
        return response(
            status: usageStatus,
            body:
                #"{"planUsage":{"totalSpend":0,"limit":100,"totalPercentUsed":0},"enabled":true}"#,
            request: request)
    }

    private func response(status: Int, body: String, request: URLRequest) -> (
        Data, HTTPURLResponse
    ) {
        (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

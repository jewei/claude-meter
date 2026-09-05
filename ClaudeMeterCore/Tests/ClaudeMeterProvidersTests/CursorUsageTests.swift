import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("Cursor usage")
struct CursorUsageTests {

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

    @Test func opaqueTokenTreatedAsExpiringSoon() {
        #expect(CursorTokenStore.expiry(of: "not-a-jwt") == nil)
        #expect(CursorTokenStore.isExpiringSoon("not-a-jwt") == true)
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

    @Test func refreshResponseDecodesRotatedRefreshToken() throws {
        let json = """
            { "access_token": "new-access", "refresh_token": "new-refresh" }
            """
        let response = try JSONDecoder().decode(CursorOAuthResponse.self, from: Data(json.utf8))
        #expect(response.accessToken == "new-access")
        #expect(response.refreshToken == "new-refresh")
    }

    @Test func switchingDetectedAccountInvalidatesRefreshedTokenCache() async throws {
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

    @Test func unauthorizedProactiveRefreshKeepsTheRotatedRefreshToken() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceAccess = Self.makeJWT(exp: now.addingTimeInterval(30).timeIntervalSince1970)
        let transport = CursorRotatedChainTransport()
        let provider = CursorUsageProvider(
            transport: transport,
            credentialsLoader: {
                CursorCredentials(
                    accessToken: sourceAccess,
                    refreshToken: "source-refresh",
                    email: nil,
                    membership: "pro")
            })

        _ = try await provider.fetchUsage(now: now)

        #expect(await transport.refreshTokens == ["source-refresh", "new-refresh"])
        #expect(
            await transport.authorizationHeaders == [
                "Bearer new-access", "Bearer \(sourceAccess)", "Bearer final-access",
            ])
    }

    @Test func metadataChangeKeepsTheRotatedRefreshTokenChain() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceAccess = Self.makeJWT(exp: now.addingTimeInterval(30).timeIntervalSince1970)
        let refreshedAccess = Self.makeJWT(
            exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
        let credentials = MutableCursorCredentialSource(
            CursorCredentials(
                accessToken: sourceAccess,
                refreshToken: "source-refresh",
                email: "old@example.com",
                membership: "pro"))
        let transport = CursorMetadataChangeTransport(refreshedAccessToken: refreshedAccess)
        let provider = CursorUsageProvider(
            transport: transport,
            credentialsLoader: { credentials.value })

        _ = try await provider.fetchUsage(now: now)
        credentials.value = CursorCredentials(
            accessToken: sourceAccess,
            refreshToken: "source-refresh",
            email: "new@example.com",
            membership: "business")
        let updated = try await provider.fetchUsage(now: now)

        #expect(updated.email == "new@example.com")
        #expect(updated.planName == "business")
        #expect(await transport.refreshTokens == ["source-refresh"])
        #expect(
            await transport.authorizationHeaders == [
                "Bearer \(refreshedAccess)", "Bearer \(refreshedAccess)",
            ])
    }

    @Test func lateRefreshCannotOverwriteANewerAccount() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let accountAAccess = Self.makeJWT(exp: now.addingTimeInterval(30).timeIntervalSince1970)
        let accountBAccess = Self.makeJWT(
            exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
        let credentials = MutableCursorCredentialSource(
            CursorCredentials(
                accessToken: accountAAccess,
                refreshToken: "account-a-refresh",
                email: "a@example.com",
                membership: "pro"))
        let transport = CursorAccountSwitchTransport()
        let provider = CursorUsageProvider(
            transport: transport,
            credentialsLoader: { credentials.value })

        let oldFetch = Task { try await provider.fetchUsage(now: now) }
        await transport.waitUntilRefreshStarts()
        credentials.value = CursorCredentials(
            accessToken: accountBAccess,
            refreshToken: "account-b-refresh",
            email: "b@example.com",
            membership: "business")

        let current = try await provider.fetchUsage(now: now)
        await transport.releaseRefresh()
        await #expect(throws: CancellationError.self) {
            try await oldFetch.value
        }
        let next = try await provider.fetchUsage(now: now)

        #expect(current.email == "b@example.com")
        #expect(next.email == "b@example.com")
        #expect(await transport.refreshTokens == ["account-a-refresh"])
        #expect(
            await transport.authorizationHeaders == [
                "Bearer \(accountBAccess)", "Bearer \(accountBAccess)",
            ])
    }

    @Test func concurrentSameSourceFetchesShareOneRotatingRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceAccess = Self.makeJWT(exp: now.addingTimeInterval(30).timeIntervalSince1970)
        let refreshedAccess = Self.makeJWT(
            exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
        let credentials = MutableCursorCredentialSource(
            CursorCredentials(
                accessToken: sourceAccess,
                refreshToken: "shared-source-refresh",
                email: "shared@example.com",
                membership: "pro"))
        let transport = CursorSameSourceRefreshTransport(
            refreshedAccessToken: refreshedAccess)
        let provider = CursorUsageProvider(
            transport: transport,
            credentialsLoader: { credentials.value })

        let olderFetch = Task { try await provider.fetchUsage(now: now) }
        await transport.waitUntilRefreshStarts()
        let middleFetch = Task { try await provider.fetchUsage(now: now) }
        let newestFetch = Task { try await provider.fetchUsage(now: now) }
        for _ in 0..<100 where credentials.readCount < 3 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        #expect(credentials.readCount >= 3)
        #expect(await transport.refreshTokens == ["shared-source-refresh"])

        await transport.releaseRefresh()
        var currentResults: [CursorUsage] = []
        var cancellationCount = 0
        for fetch in [olderFetch, middleFetch, newestFetch] {
            do {
                currentResults.append(try await fetch.value)
            } catch is CancellationError {
                cancellationCount += 1
            }
        }
        let current = try #require(currentResults.first)
        let next = try await provider.fetchUsage(now: now)

        #expect(currentResults.count == 1)
        #expect(cancellationCount == 2)
        #expect(current.email == "shared@example.com")
        #expect(next.email == "shared@example.com")
        #expect(await transport.refreshTokens == ["shared-source-refresh"])
        #expect(
            await transport.authorizationHeaders == [
                "Bearer \(refreshedAccess)", "Bearer \(refreshedAccess)",
            ])
    }

    @Test func preselectedCallerReusesAnAdoptedRotation() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceAccess = Self.makeJWT(exp: now.addingTimeInterval(30).timeIntervalSince1970)
        let refreshedAccess = Self.makeJWT(
            exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
        let credentials = CursorCredentials(
            accessToken: sourceAccess,
            refreshToken: "preselected-source-refresh",
            email: "shared@example.com",
            membership: "pro")
        let gate = FirstCursorRefreshPreselectionGate()
        let transport = CursorMetadataChangeTransport(refreshedAccessToken: refreshedAccess)
        let provider = CursorUsageProvider(
            transport: transport,
            credentialsLoader: { credentials },
            beforeRefreshCoordinator: { await gate.pauseFirstCaller() })

        let oldFetch = Task { try await provider.fetchUsage(now: now) }
        await gate.waitUntilFirstCallerPauses()

        // This caller completes and adopts the rotation before `oldFetch` enters
        // the coordinator with its already-selected source token.
        let current = try await provider.fetchUsage(now: now)
        #expect(current.email == "shared@example.com")
        #expect(await transport.refreshTokens == ["preselected-source-refresh"])

        await gate.releaseFirstCaller()
        await #expect(throws: CancellationError.self) {
            try await oldFetch.value
        }

        // The late caller must reuse the retained handoff. It must not submit the
        // one-use source token again or clear the adopted cache.
        let next = try await provider.fetchUsage(now: now)
        #expect(next.email == "shared@example.com")
        #expect(await transport.refreshTokens == ["preselected-source-refresh"])
        #expect(
            await transport.authorizationHeaders == [
                "Bearer \(refreshedAccess)", "Bearer \(refreshedAccess)",
            ])
    }

    @Test func rejectedDescendantCannotRestoreAnAncestorHandoff() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceAccess = Self.makeJWT(exp: now.addingTimeInterval(30).timeIntervalSince1970)
        let rotatedAccess = Self.makeJWT(
            exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
        let sourceRefresh = "cursor-ancestor-refresh"
        let credentials = CursorCredentials(
            accessToken: sourceAccess,
            refreshToken: sourceRefresh,
            email: "shared@example.com",
            membership: "pro")
        let transport = CursorRejectedDescendantTransport(
            sourceAccessToken: sourceAccess,
            rotatedAccessToken: rotatedAccess,
            sourceRefreshToken: sourceRefresh)
        let provider = CursorUsageProvider(
            transport: transport,
            credentialsLoader: { credentials })

        // Establish O -> R and retain O's completed coordinator handoff.
        _ = try await provider.fetchUsage(now: now)

        // Both access tokens now fail, and the token endpoint rejects R.
        await #expect(throws: CursorError.unauthorized) {
            try await provider.fetchUsage(now: now)
        }

        // The unchanged local source still contains consumed O. The next fetch
        // must not reuse O's retained handoff or submit O to the token endpoint.
        await #expect(throws: CursorError.unauthorized) {
            try await provider.fetchUsage(now: now)
        }
        #expect(await transport.refreshTokens == [sourceRefresh, "cursor-rotated-refresh"])
        #expect(
            await transport.authorizationHeaders == [
                "Bearer \(rotatedAccess)",
                "Bearer \(rotatedAccess)",
                "Bearer \(sourceAccess)",
                "Bearer \(sourceAccess)",
            ])
    }

    @Test func proactiveRefreshRejectionStillReturnsUsableAccessData() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceAccess = Self.makeJWT(exp: now.addingTimeInterval(30).timeIntervalSince1970)
        let credentials = CursorCredentials(
            accessToken: sourceAccess,
            refreshToken: "rejected-proactive-refresh",
            email: "shared@example.com",
            membership: "pro")
        let transport = CursorProactiveRejectionTransport()
        let provider = CursorUsageProvider(
            transport: transport,
            credentialsLoader: { credentials })

        let first = try await provider.fetchUsage(now: now)
        let second = try await provider.fetchUsage(now: now)

        #expect(first.email == "shared@example.com")
        #expect(second.email == "shared@example.com")
        #expect(await transport.refreshTokens == ["rejected-proactive-refresh"])
        #expect(
            await transport.authorizationHeaders == [
                "Bearer \(sourceAccess)", "Bearer \(sourceAccess)",
            ])
    }

    @Test func proactiveRefreshRejectionInvalidatesLineageAfterForbiddenProbe() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceAccess = Self.makeJWT(exp: now.addingTimeInterval(30).timeIntervalSince1970)
        let credentials = CursorCredentials(
            accessToken: sourceAccess,
            refreshToken: "rejected-before-forbidden",
            email: nil,
            membership: "pro")
        let transport = CursorProactiveRejectionTransport(usageStatus: 403)
        let provider = CursorUsageProvider(
            transport: transport,
            credentialsLoader: { credentials })

        await #expect(throws: CursorError.forbidden) {
            try await provider.fetchUsage(now: now)
        }
        await #expect(throws: CursorError.forbidden) {
            try await provider.fetchUsage(now: now)
        }

        #expect(await transport.refreshTokens == ["rejected-before-forbidden"])
        #expect(await transport.authorizationHeaders.count == 2)
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

private actor FirstCursorRefreshPreselectionGate {
    private var firstCallerPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseFirstCaller() async {
        guard !firstCallerPaused else { return }
        firstCallerPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilFirstCallerPauses() async {
        guard !firstCallerPaused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func releaseFirstCaller() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
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

private actor CursorRotatedChainTransport: HTTPTransport {
    private(set) var refreshTokens: [String] = []
    private(set) var authorizationHeaders: [String] = []

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        let path = request.url?.path ?? ""
        if path == "/oauth/token" {
            let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            let body = object as? [String: String]
            let refreshToken = body?["refresh_token"] ?? ""
            refreshTokens.append(refreshToken)
            let responseBody =
                refreshTokens.count == 1
                ? #"{"access_token":"new-access","refresh_token":"new-refresh"}"#
                : #"{"access_token":"final-access","refresh_token":"final-refresh"}"#
            return response(status: 200, body: responseBody, request: request)
        }

        if let header = request.value(forHTTPHeaderField: "Authorization") {
            authorizationHeaders.append(header)
        }
        if authorizationHeaders.count < 3 {
            return response(status: 401, body: "{}", request: request)
        }
        return response(
            status: 200,
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

private actor CursorMetadataChangeTransport: HTTPTransport {
    private let refreshedAccessToken: String
    private(set) var refreshTokens: [String] = []
    private(set) var authorizationHeaders: [String] = []

    init(refreshedAccessToken: String) {
        self.refreshedAccessToken = refreshedAccessToken
    }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        if request.url?.path == "/oauth/token" {
            let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            let body = object as? [String: String]
            let refreshToken = body?["refresh_token"] ?? ""
            refreshTokens.append(refreshToken)
            guard refreshTokens.count == 1 else {
                return response(status: 401, body: "{}", request: request)
            }
            return response(
                status: 200,
                body:
                    "{\"access_token\":\"\(refreshedAccessToken)\",\"refresh_token\":\"rotated-refresh\"}",
                request: request)
        }

        if let header = request.value(forHTTPHeaderField: "Authorization") {
            authorizationHeaders.append(header)
        }
        return response(
            status: 200,
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

private actor CursorAccountSwitchTransport: HTTPTransport {
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var refreshStarted = false
    private var refreshStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var refreshTokens: [String] = []
    private(set) var authorizationHeaders: [String] = []

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        if request.url?.path == "/oauth/token" {
            let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            let body = object as? [String: String]
            refreshTokens.append(body?["refresh_token"] ?? "")
            refreshStarted = true
            let waiters = refreshStartWaiters
            refreshStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { refreshContinuation = $0 }
            return response(
                status: 200,
                body: #"{"access_token":"late-a-access","refresh_token":"late-a-refresh"}"#,
                request: request)
        }

        if let header = request.value(forHTTPHeaderField: "Authorization") {
            authorizationHeaders.append(header)
        }
        return response(
            status: 200,
            body:
                #"{"planUsage":{"totalSpend":0,"limit":100,"totalPercentUsed":0},"enabled":true}"#,
            request: request)
    }

    func waitUntilRefreshStarts() async {
        guard !refreshStarted else { return }
        await withCheckedContinuation { refreshStartWaiters.append($0) }
    }

    func releaseRefresh() {
        let continuation = refreshContinuation
        refreshContinuation = nil
        continuation?.resume()
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

private actor CursorSameSourceRefreshTransport: HTTPTransport {
    private let refreshedAccessToken: String
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var refreshStarted = false
    private var refreshStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var refreshTokens: [String] = []
    private(set) var authorizationHeaders: [String] = []

    init(refreshedAccessToken: String) {
        self.refreshedAccessToken = refreshedAccessToken
    }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        if request.url?.path == "/oauth/token" {
            let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            let body = object as? [String: String]
            refreshTokens.append(body?["refresh_token"] ?? "")
            refreshStarted = true
            let waiters = refreshStartWaiters
            refreshStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { refreshContinuation = $0 }
            return response(
                status: 200,
                body:
                    "{\"access_token\":\"\(refreshedAccessToken)\",\"refresh_token\":\"rotated-shared-refresh\"}",
                request: request)
        }

        if let header = request.value(forHTTPHeaderField: "Authorization") {
            authorizationHeaders.append(header)
        }
        return response(
            status: 200,
            body:
                #"{"planUsage":{"totalSpend":0,"limit":100,"totalPercentUsed":0},"enabled":true}"#,
            request: request)
    }

    func waitUntilRefreshStarts() async {
        guard !refreshStarted else { return }
        await withCheckedContinuation { refreshStartWaiters.append($0) }
    }

    func releaseRefresh() {
        let continuation = refreshContinuation
        refreshContinuation = nil
        continuation?.resume()
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

private actor CursorRejectedDescendantTransport: HTTPTransport {
    private let sourceAccessToken: String
    private let rotatedAccessToken: String
    private let sourceRefreshToken: String
    private(set) var refreshTokens: [String] = []
    private(set) var authorizationHeaders: [String] = []

    init(
        sourceAccessToken: String,
        rotatedAccessToken: String,
        sourceRefreshToken: String
    ) {
        self.sourceAccessToken = sourceAccessToken
        self.rotatedAccessToken = rotatedAccessToken
        self.sourceRefreshToken = sourceRefreshToken
    }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        if request.url?.path == "/oauth/token" {
            let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            let body = object as? [String: String]
            let refreshToken = body?["refresh_token"] ?? ""
            refreshTokens.append(refreshToken)
            if refreshToken == sourceRefreshToken {
                return response(
                    status: 200,
                    body:
                        "{\"access_token\":\"\(rotatedAccessToken)\",\"refresh_token\":\"cursor-rotated-refresh\"}",
                    request: request)
            }
            return response(status: 401, body: "{}", request: request)
        }

        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        authorizationHeaders.append(authorization)
        if authorizationHeaders.count == 1,
            authorization == "Bearer \(rotatedAccessToken)"
        {
            return response(
                status: 200,
                body:
                    #"{"planUsage":{"totalSpend":0,"limit":100,"totalPercentUsed":0},"enabled":true}"#,
                request: request)
        }
        #expect(
            authorization == "Bearer \(rotatedAccessToken)"
                || authorization == "Bearer \(sourceAccessToken)")
        return response(status: 401, body: "{}", request: request)
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

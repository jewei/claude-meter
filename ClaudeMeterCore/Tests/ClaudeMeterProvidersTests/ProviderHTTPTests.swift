import Foundation
import Security
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("RedirectGuardDelegate")
struct RedirectGuardTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func allowsSameOriginHTTPS() {
        #expect(
            RedirectGuardDelegate.isAllowed(
                from: url("https://api.anthropic.com/api/oauth/usage"),
                to: url("https://api.anthropic.com/api/oauth/usage?x=1")))
    }

    @Test func blocksCrossHost() {
        #expect(
            !RedirectGuardDelegate.isAllowed(
                from: url("https://api.anthropic.com/x"),
                to: url("https://evil.example.com/x")))
    }

    @Test func blocksHTTPSDowngrade() {
        #expect(
            !RedirectGuardDelegate.isAllowed(
                from: url("https://claude.ai/x"),
                to: url("http://claude.ai/x")))
    }

    @Test func blocksDifferentPort() {
        #expect(
            !RedirectGuardDelegate.isAllowed(
                from: url("https://claude.ai/x"),
                to: url("https://claude.ai:8443/x")))
    }

    @Test func blocksNil() {
        #expect(!RedirectGuardDelegate.isAllowed(from: nil, to: url("https://claude.ai")))
    }
}

@Suite("HTTPRetryPolicy")
struct HTTPRetryPolicyTests {
    @Test func retriesIdempotentTransientStatus() {
        #expect(HTTPRetryPolicy.transient.shouldRetry(attempt: 0, method: "GET", status: 503))
        #expect(HTTPRetryPolicy.transient.shouldRetry(attempt: 0, method: "HEAD", status: 503))
        #expect(!HTTPRetryPolicy.transient.shouldRetry(attempt: 0, method: "GET", status: 429))
    }

    @Test func doesNotRetryNonIdempotentOrExhausted() {
        #expect(!HTTPRetryPolicy.transient.shouldRetry(attempt: 0, method: "POST", status: 503))
        // `transient` allows one retry, so attempt 1 is exhausted.
        #expect(!HTTPRetryPolicy.transient.shouldRetry(attempt: 1, method: "GET", status: 503))
        #expect(!HTTPRetryPolicy.transient.shouldRetry(attempt: 0, method: "GET", status: 404))
        #expect(!HTTPRetryPolicy.none.shouldRetry(attempt: 0, method: "GET", status: 429))
    }

    @Test func honorsRetryAfterCappedAtMax() {
        let policy = HTTPRetryPolicy(maxRetries: 2, baseDelay: 1, maxDelay: 8)
        #expect(policy.delay(attempt: 0, retryAfter: "5") == 5)
        #expect(policy.delay(attempt: 0, retryAfter: "100") == 8)  // capped
    }

    @Test func exponentialBackoffWhenNoRetryAfter() {
        let policy = HTTPRetryPolicy(maxRetries: 5, baseDelay: 1, maxDelay: 8)
        #expect(policy.delay(attempt: 0, retryAfter: nil) == 1)
        #expect(policy.delay(attempt: 1, retryAfter: nil) == 2)
        #expect(policy.delay(attempt: 2, retryAfter: nil) == 4)
        #expect(policy.delay(attempt: 9, retryAfter: nil) == 8)  // capped
    }

    /// `/api/oauth/usage` has been observed answering a 429 with `Retry-After: 0`
    /// while continuing to reject. Taken literally that means "no backoff", which
    /// turns a retry into a tight loop — a non-positive directive must read as
    /// "absent" so the caller falls back to its own default.
    @Test func nonPositiveRetryAfterIsTreatedAsAbsent() {
        #expect(HTTPRetryPolicy.retryAfterSeconds("0") == nil)
        #expect(HTTPRetryPolicy.retryAfterSeconds("-5") == nil)
        #expect(HTTPRetryPolicy.retryAfterSeconds(" 0 ") == nil)
        #expect(HTTPRetryPolicy.retryAfterSeconds("inf") == nil)
        #expect(HTTPRetryPolicy.retryAfterSeconds("nan") == nil)
        #expect(HTTPRetryPolicy.retryAfterSeconds("5") == 5)
    }

    @Test func zeroRetryAfterFallsBackToExponentialBackoff() {
        let policy = HTTPRetryPolicy(maxRetries: 5, baseDelay: 1, maxDelay: 8)
        #expect(policy.delay(attempt: 0, retryAfter: "0") == 1)
        #expect(policy.delay(attempt: 2, retryAfter: "0") == 4)
        #expect(policy.delay(attempt: 0, retryAfter: "-30") == 1)
    }

    @Test func pastHTTPDateIsTreatedAsAbsent() {
        let now = Date(timeIntervalSince1970: 784_111_777)  // 1994-11-06T08:49:37Z
        #expect(
            HTTPRetryPolicy.retryAfterSeconds("Sun, 06 Nov 1994 08:47:37 GMT", now: now) == nil)
        let future = HTTPRetryPolicy.retryAfterSeconds(
            "Sun, 06 Nov 1994 08:51:37 GMT", now: now)
        #expect(abs((future ?? 0) - 120) < 1)
    }

    @Test func nonFiniteDelaysAreSanitized() {
        let infinite = HTTPRetryPolicy(maxRetries: 1, baseDelay: .infinity, maxDelay: .infinity)
        #expect(infinite.baseDelay == 0)
        #expect(infinite.maxDelay == 0)
        #expect(infinite.delay(attempt: 0, retryAfter: nil) == 0)

        let nan = HTTPRetryPolicy(maxRetries: 1, baseDelay: .nan, maxDelay: 8)
        #expect(nan.baseDelay == 0)
    }
}

@Suite("ProviderHTTPClient bounds")
struct ProviderHTTPClientBoundsTests {
    @Test func rejectsOversizedDeclaredContentLengthBeforeBodyReceipt() {
        let response = HTTPURLResponse(
            url: URL(string: "https://provider-http.test/declared")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "9"]
        )!

        #expect(
            ProviderHTTPClient.declaredLengthExceedsLimit(response, maximumByteCount: 8)
        )
    }

    @Test func rejectsStreamedBodyWhenItCrossesLimit() async {
        let fixture = makeHTTPFixture(
            plan: ProviderHTTPTestPlan(
                chunks: [Data(repeating: 1, count: 5), Data(repeating: 2, count: 4)]
            ),
            maximumResponseByteCount: 8
        )
        defer { fixture.close() }

        await expectURLError(.dataLengthExceedsMaximum) {
            _ = try await fixture.client.send(URLRequest(url: fixture.url))
        }
    }

    @Test func totalDeadlineEndsAnOpenBodyAfterDataArrives() async {
        let bodyDelivered = LockedFlag()
        let fixture = makeHTTPFixture(
            plan: ProviderHTTPTestPlan(
                chunks: [Data([1]), Data([2]), Data([3])],
                finishes: false,
                afterChunks: {
                    bodyDelivered.set()
                }
            ),
            maximumResponseByteCount: 8,
            resourceTimeoutSeconds: 1
        )
        defer { fixture.close() }

        await expectURLError(.timedOut) {
            _ = try await fixture.client.send(URLRequest(url: fixture.url))
        }
        #expect(bodyDelivered.value)
    }

    @Test func totalDeadlineDoesNotAwaitCancellationIgnoringReceiver() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let receiverFinished = LockedFlag()
        let url = URL(string: "https://provider-http.test/cancellation-ignoring")!
        let session = URLSession(configuration: .ephemeral)
        let client = ProviderHTTPClient(
            session: session,
            maximumResponseByteCount: 8,
            resourceTimeoutSeconds: 0.05,
            responseLoader: { request, _, _ in
                started.signal()
                waitIgnoringCancellation(release)
                receiverFinished.set()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
        )
        let requestTask = Task {
            try await client.send(URLRequest(url: url))
        }
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { release.signal() }
        }
        defer {
            watchdog.cancel()
            release.signal()
            requestTask.cancel()
            session.invalidateAndCancel()
        }

        #expect(waitForSignal(started, timeout: .now() + 1))
        await expectURLError(.timedOut) {
            _ = try await requestTask.value
        }
        #expect(!receiverFinished.value)
    }

    @Test func callerCancellationStopsAnOpenResponse() async {
        let bodyDelivered = LockedFlag()
        let fixture = makeHTTPFixture(
            plan: ProviderHTTPTestPlan(
                chunks: [Data([1])],
                finishes: false,
                afterChunks: { bodyDelivered.set() }
            ),
            maximumResponseByteCount: 8,
            resourceTimeoutSeconds: 5
        )
        defer { fixture.close() }
        let requestTask = Task {
            try await fixture.client.send(URLRequest(url: fixture.url))
        }
        defer { requestTask.cancel() }

        let didReceiveBody = await waitForFlag(bodyDelivered)
        #expect(didReceiveBody)
        requestTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await requestTask.value
        }
    }

    @Test func preservesBoundedResponseStatusHeadersAndBody() async throws {
        let fixture = makeHTTPFixture(
            plan: ProviderHTTPTestPlan(
                status: 418,
                headers: ["X-Test": "kept"],
                chunks: [Data("hello".utf8)]
            ),
            maximumResponseByteCount: 5
        )
        defer { fixture.close() }

        let (data, response) = try await fixture.client.send(URLRequest(url: fixture.url))
        #expect(data == Data("hello".utf8))
        #expect(response.statusCode == 418)
        #expect(response.value(forHTTPHeaderField: "X-Test") == "kept")
    }

    @Test func recognizesDeclaredLengthThatExceedsIntegerRange() {
        let response = HTTPURLResponse(
            url: URL(string: "https://provider-http.test/large")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "99999999999999999999999999999999999999"]
        )!

        #expect(
            ProviderHTTPClient.declaredLengthExceedsLimit(response, maximumByteCount: 8)
        )
    }
}

/// Demonstrates the testability win: a client can be driven against canned
/// responses by injecting a stub transport — no network.
private struct StubTransport: HTTPTransport {
    let data: Data
    let status: Int
    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, http)
    }
}

@Suite("Transport injection")
struct TransportInjectionTests {
    @Test func statusClientParsesInjectedResponse() async {
        let json = #"{"status":{"indicator":"major","description":"Partial outage"}}"#
        let client = AnthropicStatusClient(
            transport: StubTransport(data: Data(json.utf8), status: 200))
        let status = await client.fetch()
        #expect(status?.level == .major)
        #expect(status?.description == "Partial outage")
    }

    @Test func statusClientReturnsNilOnNon200() async {
        let client = AnthropicStatusClient(
            transport: StubTransport(data: Data("{}".utf8), status: 503))
        #expect(await client.fetch() == nil)
    }
}

@Suite("Keychain status mapping")
struct KeychainStatusMappingTests {
    @Test func successWithDataIsFound() {
        let result = OAuthKeychain.mapKeychainStatus(errSecSuccess, data: Data("hi".utf8))
        #expect(result.value == "hi")
    }

    @Test func successWithoutDataIsInvalid() {
        if case .invalid = OAuthKeychain.mapKeychainStatus(errSecSuccess, data: nil) {
        } else {
            Issue.record("expected .invalid")
        }
    }

    @Test func itemNotFoundIsMissing() {
        if case .missing = OAuthKeychain.mapKeychainStatus(errSecItemNotFound, data: nil) {
        } else {
            Issue.record("expected .missing")
        }
    }

    @Test func lockedOrErrorIsTemporarilyUnavailable() {
        for status in [errSecInteractionNotAllowed, OSStatus(-99999)] {
            if case .temporarilyUnavailable = OAuthKeychain.mapKeychainStatus(status, data: nil) {
            } else {
                Issue.record("expected .temporarilyUnavailable for \(status)")
            }
        }
    }

    @Test func authFailedIsInvalid() {
        if case .invalid = OAuthKeychain.mapKeychainStatus(errSecAuthFailed, data: nil) {
        } else {
            Issue.record("expected .invalid for errSecAuthFailed")
        }
    }
}

private struct ProviderHTTPTestPlan: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data]
    var finishes = true
    var afterChunks: (@Sendable () -> Void)?
}

private final class ProviderHTTPTestPlanStore: @unchecked Sendable {
    static let shared = ProviderHTTPTestPlanStore()

    private let lock = NSLock()
    private var plans: [URL: ProviderHTTPTestPlan] = [:]

    func set(_ plan: ProviderHTTPTestPlan, for url: URL) {
        lock.withLock { plans[url] = plan }
    }

    func get(for url: URL?) -> ProviderHTTPTestPlan? {
        lock.withLock { url.flatMap { plans[$0] } }
    }

    func remove(for url: URL) {
        lock.withLock { plans[url] = nil }
    }
}

private final class ProviderHTTPTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        ProviderHTTPTestPlanStore.shared.get(for: request.url) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let plan = ProviderHTTPTestPlanStore.shared.get(for: request.url),
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: plan.status,
                httpVersion: "HTTP/1.1",
                headerFields: plan.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        plan.afterChunks?()
        if plan.finishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private struct ProviderHTTPTestFixture: Sendable {
    let client: ProviderHTTPClient
    let session: URLSession
    let url: URL

    func close() {
        ProviderHTTPTestPlanStore.shared.remove(for: url)
        session.invalidateAndCancel()
    }
}

private func makeHTTPFixture(
    plan: ProviderHTTPTestPlan,
    maximumResponseByteCount: Int,
    resourceTimeoutSeconds: TimeInterval = ProviderHTTPClient.resourceTimeoutSeconds
) -> ProviderHTTPTestFixture {
    let url = URL(string: "https://provider-http.test/\(UUID().uuidString)")!
    ProviderHTTPTestPlanStore.shared.set(plan, for: url)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderHTTPTestURLProtocol.self]
    let session = URLSession(
        configuration: configuration,
        delegate: ProviderHTTPSessionDelegate(),
        delegateQueue: nil
    )
    let client = ProviderHTTPClient(
        session: session,
        maximumResponseByteCount: maximumResponseByteCount,
        resourceTimeoutSeconds: resourceTimeoutSeconds
    )
    return ProviderHTTPTestFixture(client: client, session: session, url: url)
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }

    func set() {
        lock.withLock { stored = true }
    }
}

private func expectURLError(
    _ expected: URLError.Code,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected URL error \(expected.rawValue)")
    } catch let error as URLError {
        #expect(error.code == expected)
    } catch {
        Issue.record("Expected URL error, got \(error)")
    }
}

private func waitIgnoringCancellation(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: DispatchTime) -> Bool {
    semaphore.wait(timeout: timeout) == .success
}

private func waitForFlag(_ flag: LockedFlag) async -> Bool {
    for _ in 0..<1_000 {
        if flag.value { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

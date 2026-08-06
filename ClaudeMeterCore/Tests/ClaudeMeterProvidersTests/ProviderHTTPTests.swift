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
        #expect(!HTTPRetryPolicy.transient.shouldRetry(attempt: 1, method: "GET", status: 503))  // maxRetries=1
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

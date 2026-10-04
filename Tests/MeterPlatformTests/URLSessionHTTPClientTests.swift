import Foundation
import MeterTestSupport
import Testing

@testable import MeterPlatform

/// Serves scripted responses to URLSession. Each test uses its own host, so tests can run in
/// parallel without sharing routes.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Step: Sendable {
        case respond(status: Int, headers: [String: String], body: Data)
        case redirect(to: String)
        case fail(URLError.Code)
    }

    private static let routes = Locked<[String: [Step]]>([:])
    private static let counts = Locked<[String: Int]>([:])

    static func install(host: String, steps: [Step]) {
        routes.withLock { $0[host] = steps }
        counts.withLock { $0[host] = 0 }
    }

    static func requestCount(host: String) -> Int {
        counts.value[host] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let index = Self.counts.withLock { counts -> Int in
            defer { counts[host, default: 0] += 1 }
            return counts[host, default: 0]
        }
        let steps = Self.routes.value[host] ?? []
        guard !steps.isEmpty else { return }
        switch steps[min(index, steps.count - 1)] {
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let location):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": location])!
            var next = request
            next.url = URL(string: location)
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // When the session refuses the redirect, the 302 is the final response.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

@Suite struct URLSessionHTTPClientTests {
    private func client(maxBytes: Int = 1024) -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionHTTPClient(configuration: configuration, maxResponseBytes: maxBytes)
    }

    private func uniqueHost() -> String {
        "\(UUID().uuidString.lowercased()).example.com"
    }

    @Test func returnsStatusHeadersAndBody() async throws {
        let host = uniqueHost()
        StubProtocol.install(
            host: host,
            steps: [.respond(status: 200, headers: ["X-Value": "1"], body: Data("ok".utf8))])
        let response = try await client().send(HTTPRequest(url: URL(string: "https://\(host)/a")!))
        #expect(response.status == 200)
        #expect(response.header("x-value") == "1")
        #expect(response.body == Data("ok".utf8))
    }

    @Test func rejectsDeclaredOversizedBodies() async {
        let host = uniqueHost()
        StubProtocol.install(
            host: host,
            steps: [
                .respond(status: 200, headers: ["Content-Length": "5000"], body: Data(count: 5000))
            ])
        await #expect(throws: HTTPError.responseTooLarge(limit: 1024)) {
            try await client().send(HTTPRequest(url: URL(string: "https://\(host)/")!))
        }
    }

    @Test func rejectsStreamedOversizedBodies() async {
        let host = uniqueHost()
        StubProtocol.install(
            host: host, steps: [.respond(status: 200, headers: [:], body: Data(count: 2048))])
        await #expect(throws: HTTPError.responseTooLarge(limit: 1024)) {
            try await client().send(HTTPRequest(url: URL(string: "https://\(host)/")!))
        }
    }

    @Test func refusesRedirectsToAnotherOrigin() async {
        let host = uniqueHost()
        StubProtocol.install(host: host, steps: [.redirect(to: "https://evil.example.org/steal")])
        await #expect(throws: HTTPError.redirectRejected) {
            try await client().send(HTTPRequest(url: URL(string: "https://\(host)/")!))
        }
    }

    @Test func followsSameOriginRedirects() async throws {
        let host = uniqueHost()
        StubProtocol.install(
            host: host,
            steps: [
                .redirect(to: "https://\(host)/next"),
                .respond(status: 200, headers: [:], body: Data("moved".utf8)),
            ])
        let response = try await client().send(HTTPRequest(url: URL(string: "https://\(host)/")!))
        #expect(response.body == Data("moved".utf8))
    }

    @Test func retriesTransientServerErrorsForGET() async throws {
        let host = uniqueHost()
        StubProtocol.install(
            host: host,
            steps: [
                .respond(status: 503, headers: ["Retry-After": "1"], body: Data()),
                .respond(status: 200, headers: [:], body: Data("ok".utf8)),
            ])
        let request = HTTPRequest(url: URL(string: "https://\(host)/")!, retry: .transientFailures)
        let response = try await client().send(request)
        #expect(response.status == 200)
        #expect(StubProtocol.requestCount(host: host) == 2)
    }

    @Test func neverRetriesRateLimits() async throws {
        let host = uniqueHost()
        StubProtocol.install(host: host, steps: [.respond(status: 429, headers: [:], body: Data())])
        let request = HTTPRequest(url: URL(string: "https://\(host)/")!, retry: .transientFailures)
        #expect(try await client().send(request).status == 429)
        #expect(StubProtocol.requestCount(host: host) == 1)
    }

    @Test func neverRetriesPOST() async throws {
        let host = uniqueHost()
        StubProtocol.install(host: host, steps: [.respond(status: 503, headers: [:], body: Data())])
        let request = HTTPRequest(
            .post, url: URL(string: "https://\(host)/")!, retry: .transientFailures)
        #expect(try await client().send(request).status == 503)
        #expect(StubProtocol.requestCount(host: host) == 1)
    }

    @Test func returnsTheResponseWhenTheServerDelayDoesNotFit() async throws {
        let host = uniqueHost()
        StubProtocol.install(
            host: host, steps: [.respond(status: 503, headers: ["Retry-After": "60"], body: Data())]
        )
        let request = HTTPRequest(
            url: URL(string: "https://\(host)/")!, retry: .transientFailures, deadline: .seconds(5))
        #expect(try await client().send(request).status == 503)
        #expect(StubProtocol.requestCount(host: host) == 1)
    }

    @Test func returnsTheResponseForAHugeServerDelay() async throws {
        for delay in ["99999999999999999999999", String(repeating: "9", count: 400)] {
            let host = uniqueHost()
            StubProtocol.install(
                host: host,
                steps: [.respond(status: 503, headers: ["Retry-After": delay], body: Data())])
            let request = HTTPRequest(
                url: URL(string: "https://\(host)/")!, retry: .transientFailures)
            #expect(try await client().send(request).status == 503)
            #expect(StubProtocol.requestCount(host: host) == 1)
        }
    }

    @Test func mapsTransportFailures() async {
        let host = uniqueHost()
        StubProtocol.install(host: host, steps: [.fail(.notConnectedToInternet)])
        await #expect(throws: HTTPError.offline) {
            try await client().send(HTTPRequest(url: URL(string: "https://\(host)/")!))
        }
    }
}

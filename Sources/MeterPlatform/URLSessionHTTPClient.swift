import Foundation

/// The live HTTP client for every provider request.
///
/// - No cookies, no URL cache, and every send bypasses local caches, so a cached response can
///   never pose as a new observation.
/// - A response body above ``maxResponseBytes`` fails, before the body arrives when the
///   server declares its length.
/// - Redirects must keep the HTTPS origin, so credentials never reach another host.
/// - The request deadline covers the whole send, including retries.
public final class URLSessionHTTPClient: HTTPClient {
    public static let shared = URLSessionHTTPClient()

    public let maxResponseBytes: Int
    /// Internal so tests can check the configuration.
    let session: URLSession
    /// Three attempts wait 1 s and 2 s between them, unless the server asks for longer.
    private static let maxAttempts = 3
    /// Server states that usually pass. Never 429: rate limits have their own rules.
    private static let retryableStatuses: Set<Int> = [408, 500, 502, 503, 504]

    public convenience init(maxResponseBytes: Int = 8 * 1024 * 1024) {
        self.init(configuration: .ephemeral, maxResponseBytes: maxResponseBytes)
    }

    /// Tests pass a configuration with stub `protocolClasses`.
    init(configuration: URLSessionConfiguration, maxResponseBytes: Int) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        self.maxResponseBytes = maxResponseBytes
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let deadline = ContinuousClock.now + request.deadline
        do {
            return try await withDeadline(request.deadline) {
                try await self.sendWithRetries(request, deadline: deadline)
            }
        } catch is TimeoutError {
            throw HTTPError.timedOut
        }
    }

    private func sendWithRetries(
        _ request: HTTPRequest, deadline: ContinuousClock.Instant
    ) async throws -> HTTPResponse {
        let retries = request.retry == .transientFailures && request.method == .get
        var attempt = 1
        while true {
            let response: HTTPResponse
            do {
                response = try await sendOnce(request)
            } catch let error as HTTPError where retries && error.isTransient {
                guard attempt < Self.maxAttempts else { throw error }
                let wait = Self.backoff(attempt: attempt)
                guard Self.fits(wait, before: deadline) else { throw error }
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
                continue
            }
            guard retries, attempt < Self.maxAttempts,
                Self.retryableStatuses.contains(response.status)
            else { return response }
            // A server delay is never shortened. If it does not fit, return the response.
            let wait =
                RetryAfter.delay(response.header("retry-after"), now: Date())
                ?? Self.backoff(attempt: attempt)
            guard Self.fits(wait, before: deadline) else { return response }
            try await Task.sleep(for: .seconds(wait))
            attempt += 1
        }
    }

    private static func backoff(attempt: Int) -> TimeInterval {
        pow(2, Double(attempt - 1))
    }

    /// Compares in seconds, so a huge server delay never becomes a `Duration`, which traps.
    private static func fits(_ wait: TimeInterval, before deadline: ContinuousClock.Instant) -> Bool
    {
        wait.isFinite && wait < (deadline - ContinuousClock.now).timeInterval
    }

    private func sendOnce(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let guardDelegate = SameOriginRedirects(origin: request.url)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest, delegate: guardDelegate)
        } catch {
            throw Self.translate(error)
        }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw HTTPError.transport(code: 0)
        }
        // The redirect guard refused to follow, so the 3xx is the final response. Its body is
        // not needed.
        if (300..<400).contains(http.statusCode) {
            bytes.task.cancel()
            throw HTTPError.redirectRejected
        }
        if http.expectedContentLength > Int64(maxResponseBytes) {
            bytes.task.cancel()
            throw HTTPError.responseTooLarge(limit: maxResponseBytes)
        }

        var body = Data()
        if http.expectedContentLength > 0 {
            body.reserveCapacity(Int(http.expectedContentLength))
        }
        do {
            for try await byte in bytes {
                guard body.count < maxResponseBytes else {
                    bytes.task.cancel()
                    throw HTTPError.responseTooLarge(limit: maxResponseBytes)
                }
                body.append(byte)
            }
        } catch let error as HTTPError {
            throw error
        } catch {
            throw Self.translate(error)
        }

        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String {
                result[name] = value
            }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: body)
    }

    private static func translate(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled:
            // Only the caller's cancellation means "change nothing". The system can cancel a
            // task too, and that is a failure to report.
            return Task.isCancelled
                ? CancellationError() : HTTPError.transport(code: urlError.code.rawValue)
        case .timedOut:
            return HTTPError.timedOut
        case .networkConnectionLost:
            return HTTPError.connectionLost
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
            .internationalRoamingOff, .dataNotAllowed:
            return HTTPError.offline
        default:
            return HTTPError.transport(code: urlError.code.rawValue)
        }
    }
}

/// Follows a redirect only to the same HTTPS scheme, host, and port. A missing port is 443.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: URL

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let target = request.url,
            target.scheme?.lowercased() == "https",
            origin.scheme?.lowercased() == "https",
            target.host?.lowercased() == origin.host?.lowercased(),
            (target.port ?? 443) == (origin.port ?? 443)
        else { return nil }
        return request
    }
}

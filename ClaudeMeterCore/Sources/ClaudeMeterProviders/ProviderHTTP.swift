import ClaudeMeterCore
import Foundation

/// Abstraction over the network so pipelines can be unit-tested against canned
/// responses (inject a stub `HTTPTransport`) instead of hitting the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request, retry: .none)
    }
}

/// Bounded retry for transient failures. Defaults retry only idempotent methods,
/// honor `Retry-After`, and use exponential backoff. Kept small on purpose so a
/// poll never turns into a hammering loop (matches the app's 60 s cadence).
public struct HTTPRetryPolicy: Sendable {
    public let maxRetries: Int
    public let retryableStatus: Set<Int>
    public let idempotentMethodsOnly: Bool
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    public init(
        maxRetries: Int = 0,
        retryableStatus: Set<Int> = [408, 429, 500, 502, 503, 504],
        idempotentMethodsOnly: Bool = true,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 8
    ) {
        self.maxRetries = max(0, maxRetries)
        self.retryableStatus = retryableStatus
        self.idempotentMethodsOnly = idempotentMethodsOnly
        self.baseDelay = baseDelay.isFinite ? max(0, baseDelay) : 0
        self.maxDelay = maxDelay.isFinite ? max(0, maxDelay) : 0
    }

    /// No retries.
    public static let none = HTTPRetryPolicy(maxRetries: 0, retryableStatus: [])
    /// One retry for a transient GET/HEAD failure. Excludes 429 — callers that
    /// need rate-limit backoff (OAuth) handle it themselves.
    public static let transient = HTTPRetryPolicy(
        maxRetries: 1,
        retryableStatus: [408, 500, 502, 503, 504]
    )

    private static let idempotentMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]

    /// `status: nil` is a transport-level failure (retry any transient error);
    /// a non-nil status retries only when it's in `retryableStatus`.
    func shouldRetry(attempt: Int, method: String, status: Int? = nil) -> Bool {
        guard attempt < maxRetries else { return false }
        if let status, !retryableStatus.contains(status) { return false }
        guard idempotentMethodsOnly else { return true }
        return Self.idempotentMethods.contains(method.uppercased())
    }

    /// Backoff before the next attempt: `Retry-After` when present, else exponential.
    func delay(attempt: Int, retryAfter: String?, now: Date = Date()) -> TimeInterval {
        if let seconds = Self.retryAfterSeconds(retryAfter, now: now) {
            return min(seconds, maxDelay)
        }
        guard baseDelay > 0 else { return 0 }
        return min(baseDelay * pow(2, Double(max(0, attempt))), maxDelay)
    }

    /// Seconds to wait per a `Retry-After` header, in either RFC 9110 form:
    /// delta-seconds (`120`) or an HTTP-date (`Sun, 06 Nov 1994 08:49:37 GMT`).
    /// `nil` when absent, unparseable, **or non-positive** — every caller wants
    /// "no usable directive, fall back to my own default" in that case.
    ///
    /// Rejecting `<= 0` is load-bearing, not tidiness: `/api/oauth/usage` has been
    /// observed returning `Retry-After: 0` while continuing to 429. Taken at face
    /// value that means "no backoff" — it would open `OAuthSharedState`'s gate
    /// immediately (`blockedUntil = now`) instead of the intended 60 s, and turn a
    /// `.transient` retry into a tight loop. A past HTTP-date is the same story.
    ///
    /// The single parser for the whole module — `OAuthPipeline.retryAfterDate`
    /// delegates here so the retry path and the 429 gate can't diverge.
    static func retryAfterSeconds(_ raw: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        if let seconds = TimeInterval(value) { return seconds > 0 ? seconds : nil }
        guard let date = httpDateFormatter.date(from: value) else { return nil }
        let delta = date.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }

    // Read-only after creation; see the formatter-caching note in `JournalReader`.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter
    }()
}

/// Shared transport backed by a redirect-guarded, cookie-less ephemeral session.
///
/// Provider requests can carry bearer credentials, so following an off-origin or
/// downgraded redirect would leak them. The guard blocks any redirect that is not
/// same-origin HTTPS. Cookies are disabled to keep provider sessions isolated.
public final class ProviderHTTPClient: HTTPTransport, @unchecked Sendable {
    public static let shared = ProviderHTTPClient()

    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.guardedSession()
    }

    static func guardedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 10
        return URLSession(
            configuration: config,
            delegate: RedirectGuardDelegate(),
            delegateQueue: nil
        )
    }

    public func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard
                    retry.shouldRetry(
                        attempt: attempt,
                        method: request.httpMethod ?? "GET",
                        status: http.statusCode
                    )
                else {
                    return (data, http)
                }
                let wait = retry.delay(
                    attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                attempt += 1
            } catch let error as URLError
                where Self.isRetryableTransportError(error)
                && retry.shouldRetry(attempt: attempt, method: request.httpMethod ?? "GET")
            {
                let wait = retry.delay(attempt: attempt, retryAfter: nil)
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                attempt += 1
            }
        }
    }

    private static func isRetryableTransportError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
            .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}

/// Blocks redirects that aren't same-origin HTTPS, so credentials can't be
/// replayed to a different host or over plaintext.
final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(
            Self.isAllowed(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }

    /// Allow only when both URLs are HTTPS and share scheme + host + port.
    static func isAllowed(from origin: URL?, to destination: URL?) -> Bool {
        guard let origin, let destination,
            origin.scheme?.lowercased() == "https",
            destination.scheme?.lowercased() == "https",
            origin.host?.lowercased() == destination.host?.lowercased(),
            port(origin) == port(destination)
        else { return false }
        return true
    }

    private static func port(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

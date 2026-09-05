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
        if let seconds = TimeInterval(value) {
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let delta = date.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }
}

/// Shared transport backed by a redirect-guarded, cookie-less ephemeral session.
///
/// Provider requests can carry bearer credentials, so following an off-origin or
/// downgraded redirect would leak them. The guard blocks any redirect that is not
/// same-origin HTTPS. Cookies are disabled to keep provider sessions isolated.
public final class ProviderHTTPClient: HTTPTransport, @unchecked Sendable {
    public static let shared = ProviderHTTPClient()

    /// Provider responses are small JSON except the models.dev catalog, which is
    /// larger than 4 MiB. Eight MiB gives that catalog headroom without permitting
    /// an unbounded response allocation.
    static let maximumResponseByteCount = 8 * 1_024 * 1_024
    static let requestTimeoutSeconds: TimeInterval = 10
    static let resourceTimeoutSeconds: TimeInterval = 30

    /// A URL task should stop promptly when canceled, but keep a separate cap for
    /// implementations that do not. Repeated network deadlines cannot consume the
    /// process-wide timeout capacity or create an unbounded set of abandoned tasks.
    private static let requestTaskBudget = Timeout.TaskBudget(limit: 16)

    private let session: URLSession
    private let responseByteLimit: Int
    private let attemptTimeoutSeconds: TimeInterval
    private let responseLoader:
        @Sendable (
            URLRequest, URLSession, Int
        ) async throws -> (Data, HTTPURLResponse)

    public init(session injectedSession: URLSession? = nil) {
        if let injectedSession {
            self.session = injectedSession
            self.responseLoader = Self.receiveBytes
        } else {
            let delegate = ProviderHTTPSessionDelegate()
            self.session = Self.guardedSession(delegate: delegate)
            self.responseLoader = { request, session, maximumByteCount in
                try await delegate.receive(
                    request: request,
                    session: session,
                    maximumByteCount: maximumByteCount
                )
            }
        }
        self.responseByteLimit = Self.maximumResponseByteCount
        self.attemptTimeoutSeconds = Self.resourceTimeoutSeconds
    }

    init(
        session: URLSession,
        maximumResponseByteCount: Int,
        resourceTimeoutSeconds: TimeInterval,
        responseLoader: (
            @Sendable (
                URLRequest, URLSession, Int
            ) async throws -> (Data, HTTPURLResponse)
        )? = nil
    ) {
        precondition(maximumResponseByteCount >= 0)
        precondition(resourceTimeoutSeconds.isFinite && resourceTimeoutSeconds > 0)
        self.session = session
        self.responseByteLimit = maximumResponseByteCount
        self.attemptTimeoutSeconds = resourceTimeoutSeconds
        if let responseLoader {
            self.responseLoader = responseLoader
        } else if let delegate = session.delegate as? ProviderHTTPSessionDelegate {
            self.responseLoader = { request, session, maximumByteCount in
                try await delegate.receive(
                    request: request,
                    session: session,
                    maximumByteCount: maximumByteCount
                )
            }
        } else {
            self.responseLoader = Self.receiveBytes
        }
    }

    static func guardedSession(delegate: ProviderHTTPSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = requestTimeoutSeconds
        config.timeoutIntervalForResource = resourceTimeoutSeconds
        return URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    public func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        var boundedRequest = request
        if !request.timeoutInterval.isFinite || request.timeoutInterval <= 0
            || request.timeoutInterval > Self.requestTimeoutSeconds
        {
            boundedRequest.timeoutInterval = Self.requestTimeoutSeconds
        }
        let deadlineRequest = boundedRequest
        let timeoutSeconds = attemptTimeoutSeconds
        do {
            return try await Timeout.run(
                seconds: timeoutSeconds,
                budget: Self.requestTaskBudget
            ) {
                try await self.sendWithinDeadline(deadlineRequest, retry: retry)
            }
        } catch is TimeoutError {
            // Keep the transport's established URL-loading error contract when
            // the hard resource deadline expires.
            throw URLError(.timedOut)
        }
    }

    private func sendWithinDeadline(
        _ request: URLRequest,
        retry: HTTPRetryPolicy
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, http) = try await loadBoundedResponse(for: request)
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

    private func loadBoundedResponse(for request: URLRequest) async throws -> (
        Data, HTTPURLResponse
    ) {
        let session = session
        let maximumByteCount = responseByteLimit
        let load = responseLoader
        return try await load(request, session, maximumByteCount)
    }

    private static func receiveBytes(
        request: URLRequest,
        session: URLSession,
        maximumByteCount: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }

        let transferTask = bytes.task
        return try await withTaskCancellationHandler {
            guard !declaredLengthExceedsLimit(http, maximumByteCount: maximumByteCount) else {
                transferTask.cancel()
                throw responseTooLargeError()
            }

            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(
                    min(Int(response.expectedContentLength), maximumByteCount)
                )
            }

            for try await byte in bytes {
                guard data.count < maximumByteCount else {
                    transferTask.cancel()
                    throw responseTooLargeError()
                }
                data.append(byte)
            }
            return (data, http)
        } onCancel: {
            transferTask.cancel()
        }
    }

    static func declaredLengthExceedsLimit(
        _ response: HTTPURLResponse,
        maximumByteCount: Int
    ) -> Bool {
        let expected = response.expectedContentLength
        if expected > Int64(maximumByteCount) { return true }

        // `expectedContentLength` can be unknown for malformed or very large
        // values. Parse valid decimal header fields too, without integer overflow.
        guard let raw = response.value(forHTTPHeaderField: "Content-Length") else {
            return false
        }
        let maximum = String(maximumByteCount)
        return raw.split(separator: ",").contains { component in
            let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
                return false
            }
            let normalized = String(value.drop(while: { $0 == "0" }))
            guard !normalized.isEmpty else { return false }
            if normalized.count != maximum.count {
                return normalized.count > maximum.count
            }
            return normalized > maximum
        }
    }

    private static func responseTooLargeError() -> URLError {
        URLError(.dataLengthExceedsMaximum)
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

/// Receives provider bodies in URLSession-sized chunks and stops the task before
/// the retained body can grow past its fixed limit.
final class ProviderHTTPSessionDelegate: RedirectGuardDelegate, URLSessionDataDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var receivers: [Int: ProviderHTTPResponseReceiver] = [:]

    func receive(
        request: URLRequest,
        session: URLSession,
        maximumByteCount: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let task = session.dataTask(with: request)
        let receiver = ProviderHTTPResponseReceiver(maximumByteCount: maximumByteCount)
        lock.withLock { receivers[task.taskIdentifier] = receiver }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.install(continuation)
                if Task.isCancelled {
                    cancel(task)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel(task)
        }
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let receiver = receiver(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        guard
            let error = receiver.accept(
                response: response,
                taskExpectedContentLength: dataTask.countOfBytesExpectedToReceive
            )
        else {
            completionHandler(.allow)
            return
        }

        _ = takeReceiver(for: dataTask.taskIdentifier)
        receiver.resolve(.failure(error))
        completionHandler(.cancel)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let receiver = receiver(for: dataTask.taskIdentifier),
            let error = receiver.append(data)
        else { return }

        _ = takeReceiver(for: dataTask.taskIdentifier)
        dataTask.cancel()
        receiver.resolve(.failure(error))
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let receiver = takeReceiver(for: task.taskIdentifier) else { return }
        if let error {
            receiver.resolve(.failure(error))
        } else {
            receiver.resolve(receiver.completedResult())
        }
    }

    private func receiver(for taskIdentifier: Int) -> ProviderHTTPResponseReceiver? {
        lock.withLock { receivers[taskIdentifier] }
    }

    private func takeReceiver(for taskIdentifier: Int) -> ProviderHTTPResponseReceiver? {
        lock.withLock { receivers.removeValue(forKey: taskIdentifier) }
    }

    private func cancel(_ task: URLSessionTask) {
        let receiver = takeReceiver(for: task.taskIdentifier)
        task.cancel()
        receiver?.resolve(.failure(CancellationError()))
    }
}

private final class ProviderHTTPResponseReceiver: @unchecked Sendable {
    typealias Output = (Data, HTTPURLResponse)

    private let lock = NSLock()
    private let maximumByteCount: Int
    private var body = Data()
    private var response: HTTPURLResponse?
    private var result: Result<Output, Error>?
    private var continuation: CheckedContinuation<Output, Error>?

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
    }

    func install(_ continuation: CheckedContinuation<Output, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func accept(
        response: URLResponse,
        taskExpectedContentLength: Int64
    ) -> (any Error)? {
        guard let http = response as? HTTPURLResponse else {
            return URLError(.badServerResponse)
        }
        guard taskExpectedContentLength <= Int64(maximumByteCount),
            !ProviderHTTPClient.declaredLengthExceedsLimit(
                http,
                maximumByteCount: maximumByteCount
            )
        else {
            return URLError(.dataLengthExceedsMaximum)
        }

        lock.withLock {
            self.response = http
            if response.expectedContentLength > 0 {
                body.reserveCapacity(
                    min(Int(response.expectedContentLength), maximumByteCount)
                )
            }
        }
        return nil
    }

    func append(_ chunk: Data) -> (any Error)? {
        lock.withLock {
            guard result == nil else { return nil }
            guard chunk.count <= maximumByteCount - body.count else {
                return URLError(.dataLengthExceedsMaximum)
            }
            body.append(chunk)
            return nil
        }
    }

    func completedResult() -> Result<Output, Error> {
        lock.withLock {
            guard let response else {
                return .failure(URLError(.badServerResponse))
            }
            return .success((body, response))
        }
    }

    func resolve(_ outcome: Result<Output, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(with: outcome)
    }
}

/// Blocks redirects that aren't same-origin HTTPS, so credentials can't be
/// replayed to a different host or over plaintext.
class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

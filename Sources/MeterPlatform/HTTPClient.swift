import Foundation

/// A request to a provider API.
public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public enum Retry: Sendable {
        /// Send once. Use for every request with its own rate-limit rules.
        case never
        /// Retry a GET after a dropped connection or HTTP 408, 500, 502, 503, or 504.
        /// Never after 429.
        case transientFailures
    }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var retry: Retry
    /// The limit for the whole send, including retries and their waits.
    public var deadline: Duration

    public init(
        _ method: Method = .get,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        retry: Retry = .never,
        deadline: Duration = .seconds(30)
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.retry = retry
        self.deadline = deadline
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    /// Header names are lowercased.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var isSuccess: Bool {
        (200..<300).contains(status)
    }
}

/// Sends HTTP requests. Inject a fake in tests; use ``URLSessionHTTPClient/shared`` in the app.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum HTTPError: Error, Equatable, LocalizedError, Sendable {
    /// The response body passed the size limit.
    case responseTooLarge(limit: Int)
    /// The server redirected to another origin. Credentials never follow.
    case redirectRejected
    /// The network is down or the host cannot be found.
    case offline
    case timedOut
    /// Another transport failure, with its `URLError` code.
    case transport(code: Int)

    public var errorDescription: String? {
        switch self {
        case .responseTooLarge: "The server sent a response that is too large."
        case .redirectRejected: "The server redirected to another site."
        case .offline: "The network is unavailable."
        case .timedOut: "The server did not respond in time."
        case .transport(let code): "The network request failed (\(code))."
        }
    }

    var isTransient: Bool {
        switch self {
        case .offline, .timedOut, .transport: true
        case .responseTooLarge, .redirectRejected: false
        }
    }
}

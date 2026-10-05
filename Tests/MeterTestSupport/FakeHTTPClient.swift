import Foundation
import MeterPlatform

/// An HTTP client that answers from a script and records every request.
public final class FakeHTTPClient: HTTPClient {
    public typealias Responder = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let responder: Responder
    private let log = Locked<[HTTPRequest]>([])

    public init(_ responder: @escaping Responder) {
        self.responder = responder
    }

    /// Answers every request with the same status and JSON body.
    public convenience init(status: Int = 200, json: String, headers: [String: String] = [:]) {
        self.init { _ in HTTPResponse(status: status, headers: headers, body: Data(json.utf8)) }
    }

    /// Answers requests in order; the last response repeats. `sequence` must not be empty.
    public convenience init(sequence: [Result<HTTPResponse, any Error>]) {
        precondition(
            !sequence.isEmpty, "FakeHTTPClient(sequence:) needs at least one response to repeat.")
        let remaining = Locked(sequence)
        self.init { _ in
            let next = remaining.withLock { queue -> Result<HTTPResponse, any Error> in
                queue.count > 1 ? queue.removeFirst() : queue[0]
            }
            return try next.get()
        }
    }

    public var requests: [HTTPRequest] { log.value }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        return try await responder(request)
    }
}

extension HTTPResponse {
    public static func json(_ status: Int = 200, _ body: String, headers: [String: String] = [:])
        -> HTTPResponse
    {
        HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
    }
}

import Foundation
import MeterDomain
import MeterPlatform

/// Why a usage request produced no usage.
enum UsageFailure: Error, Equatable {
    /// HTTP 429 now or earlier: the shared gate blocks requests until `until`.
    case rateLimited(until: Date?)
    /// HTTP 401 or 403: the token was rejected.
    case unauthorized
    case httpStatus(Int)
    case invalidResponse
    /// The request did not complete, with the transport's reason.
    case transport(String)
}

/// `GET /api/oauth/usage` for one access token, behind the shared 429 gate.
struct UsageAPI: Sendable {
    // Compile-time literals.
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!
    /// Claude Code's own User-Agent format. The server decides reset-grant eligibility by
    /// client surface: the older `claude-code/<version>` form gets `ineligible_reason: surface`.
    static let userAgent = "claude-cli/2.1.280 (external, cli)"
    static let betaHeader = "oauth-2025-04-20"
    static let requestDeadline: Duration = .seconds(15)

    let http: any HTTPClient
    let gate: RateLimitGate
    let now: @Sendable () -> Date

    static func request(accessToken: String) -> HTTPRequest {
        HTTPRequest(
            .get, url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "anthropic-beta": betaHeader,
                "Accept": "application/json",
                "User-Agent": userAgent,
            ],
            retry: .never, deadline: requestDeadline)
    }

    /// Sends one request unless the gate is closed. Throws ``UsageFailure``, or
    /// `CancellationError` when the caller was cancelled.
    func usage(accessToken: String) async throws -> UsageResponse {
        if let until = gate.blockedUntil(now: now()) {
            throw UsageFailure.rateLimited(until: until)
        }
        let response: HTTPResponse
        do {
            response = try await http.send(Self.request(accessToken: accessToken))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw UsageFailure.transport(error.localizedDescription)
        }
        switch response.status {
        case 200:
            do {
                return try UsageResponse(data: response.body, now: now())
            } catch {
                throw UsageFailure.invalidResponse
            }
        case 401, 403:
            throw UsageFailure.unauthorized
        case 429:
            let until = gate.recordRateLimit(retryAfter: response.header("retry-after"), now: now())
            throw UsageFailure.rateLimited(until: until)
        default:
            throw UsageFailure.httpStatus(response.status)
        }
    }
}

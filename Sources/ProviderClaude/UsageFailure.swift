import Foundation

/// Why a usage request produced no usage.
enum UsageFailure: Error, Equatable {
    /// HTTP 429 now or earlier: the shared gate blocks requests until `until`.
    case rateLimited(until: Date?)
    /// HTTP 401: the access token is not valid. A manual refresh token can still work.
    case unauthorized
    /// HTTP 403: the token is valid but may not read usage, for example because a scope is
    /// missing. A refresh does not change the scopes.
    case forbidden
    case httpStatus(Int)
    case invalidResponse
    /// The request did not complete, with the transport's reason.
    case transport(String)

    /// The server rejected the token: HTTP 401 or 403.
    var isRejection: Bool { self == .unauthorized || self == .forbidden }
}

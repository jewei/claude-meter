import Foundation
import MeterDomain
import MeterPlatform

/// Every expected way a Grok refresh can fail, with the text that the user sees.
enum GrokFailure: Error, Equatable, Sendable {
    /// `auth.json` is missing or has no entry with a key.
    case signedOut
    /// Every usable entry has an `expires_at` in the past. No token is sent.
    case sessionExpired
    /// The billing endpoint answered HTTP 401.
    case sessionRejected
    /// The billing endpoint answered HTTP 403: the login is valid but has no access, for
    /// example without a plan. A new login does not help.
    case accessDenied
    /// The billing endpoint answered HTTP 429.
    case rateLimited(retryAt: Date?)
    /// Any other HTTP status.
    case httpStatus(Int)
    case unexpectedResponse
    case offline
    case timedOut
    case network
    /// `auth.json` exists but cannot be read or parsed.
    case credentialsUnreadable
    /// The file read did not finish in time.
    case credentialsBusy
    /// The login changed while a request was in flight. The response is discarded.
    case signInChanged

    var issue: UsageIssue {
        switch self {
        case .signedOut:
            UsageIssue(
                "Grok Build is not signed in. Install grok and run `grok login`.",
                needsAction: true)
        case .sessionExpired:
            UsageIssue(
                "Your Grok sign-in expired. Open Grok Build to renew it.", needsAction: true)
        case .sessionRejected:
            UsageIssue(
                "Grok did not accept the sign-in. Open Grok Build and run `grok login`.",
                needsAction: true)
        case .accessDenied:
            UsageIssue(
                "Grok denied access to usage data. Check your Grok plan.", needsAction: true)
        case .rateLimited(let retryAt):
            UsageIssue(
                "Grok limited the number of requests. Claude Meter will try again later.",
                retryAt: retryAt)
        case .httpStatus(let status):
            UsageIssue(
                "The Grok usage request failed (HTTP \(status)). Claude Meter will try again soon."
            )
        case .unexpectedResponse:
            UsageIssue("Grok returned an unexpected response. Claude Meter will try again soon.")
        case .offline:
            UsageIssue("Cannot reach Grok. Check your internet connection.")
        case .timedOut:
            UsageIssue("Grok did not respond in time. Claude Meter will try again soon.")
        case .network:
            UsageIssue("The Grok usage request failed. Claude Meter will try again soon.")
        case .credentialsUnreadable:
            UsageIssue(
                "Could not read the Grok sign-in file (auth.json). If this continues, run `grok login`."
            )
        case .credentialsBusy:
            UsageIssue(
                "Reading the Grok sign-in file took too long. Claude Meter will try again soon.")
        case .signInChanged:
            UsageIssue(
                "The Grok account changed during the refresh. Refresh again to show the new account."
            )
        }
    }

    /// Maps a transport error. Callers rethrow cancellation first. A connection that dropped
    /// had reached the server, so it is a temporary failure, not a network that is down.
    init(transport error: any Error) {
        switch error as? HTTPError {
        case .offline: self = .offline
        case .timedOut: self = .timedOut
        case .responseTooLarge, .redirectRejected: self = .unexpectedResponse
        case .connectionLost, .transport, nil: self = .network
        }
    }

    /// Maps a non-success HTTP status.
    init(status: Int, retryAfter: String?, now: Date) {
        switch status {
        case 401: self = .sessionRejected
        case 403: self = .accessDenied
        case 429:
            self = .rateLimited(
                retryAt: RateLimitHold.retryAt(
                    delay: RetryAfter.delay(retryAfter, now: now), now: now))
        default: self = .httpStatus(status)
        }
    }
}

extension GrokFailure: CaseIterable {
    /// Every case once, with one value for each associated value. Add a new case here: the
    /// message test switches over every case and runs over this list.
    static let allCases: [GrokFailure] = [
        .signedOut, .sessionExpired, .sessionRejected, .accessDenied, .rateLimited(retryAt: nil),
        .httpStatus(500), .unexpectedResponse, .offline, .timedOut, .network,
        .credentialsUnreadable, .credentialsBusy, .signInChanged,
    ]
}

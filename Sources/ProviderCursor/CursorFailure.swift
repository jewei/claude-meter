import Foundation
import MeterDomain
import MeterPlatform

/// Every expected way a Cursor refresh can fail, with the text that the user sees.
enum CursorFailure: Error, Equatable, Sendable {
    /// No access token in the state database or the Keychain.
    case signedOut
    /// The access token has a known expiry in the past. It is never sent.
    case sessionExpired
    /// Cursor answered HTTP 401.
    case sessionRejected
    /// Cursor answered HTTP 403.
    case accessDenied
    /// The usage response says that usage is off for this account.
    case usageDisabled
    /// Cursor answered HTTP 429.
    case rateLimited(retryAt: Date?)
    /// Any other HTTP status.
    case httpStatus(Int)
    /// The body or the access token does not have the expected shape.
    case unexpectedResponse
    case unexpectedToken
    case offline
    case timedOut
    case network
    /// SQLite reported a lock, or the read did not finish in time.
    case credentialsBusy
    /// The state database exists but cannot be read, and the Keychain has no token.
    case credentialsUnreadable
    /// The Keychain is locked or refused the read.
    case keychainUnavailable
    /// The login changed while a request was in flight. The response is discarded.
    case signInChanged
    /// The local clock gives no valid seven-day range.
    case invalidDate

    var issue: UsageIssue {
        switch self {
        case .signedOut:
            UsageIssue("Cursor is not signed in. Open Cursor and sign in.", needsAction: true)
        case .sessionExpired:
            UsageIssue(
                "Your Cursor session expired. Open Cursor to renew it.", needsAction: true)
        case .sessionRejected:
            UsageIssue(
                "Cursor did not accept the session. Open Cursor and sign in again.",
                needsAction: true)
        case .accessDenied:
            UsageIssue(
                "Cursor denied access to usage data. Check your Cursor account permissions.",
                needsAction: true)
        case .usageDisabled:
            UsageIssue(
                "Cursor does not report usage for this account. Check the account in the Cursor dashboard.",
                needsAction: true)
        case .rateLimited(let retryAt):
            UsageIssue(
                "Cursor limited the number of requests. Claude Meter will try again later.",
                retryAt: retryAt)
        case .httpStatus(let status):
            UsageIssue(
                "The Cursor request failed (HTTP \(status)). Claude Meter will try again soon.")
        case .unexpectedResponse:
            UsageIssue(
                "Cursor returned an unexpected response. Claude Meter will try again soon.")
        case .unexpectedToken:
            UsageIssue(
                "The Cursor sign-in token has an unexpected format. Update Claude Meter if this continues."
            )
        case .offline:
            UsageIssue("Cannot reach Cursor. Check your internet connection.")
        case .timedOut:
            UsageIssue("Cursor did not respond in time. Claude Meter will try again soon.")
        case .network:
            UsageIssue("The Cursor request failed. Claude Meter will try again soon.")
        case .credentialsBusy:
            UsageIssue(
                "The Cursor credential database is busy. Claude Meter will try again soon.")
        case .credentialsUnreadable:
            UsageIssue(
                "Could not read Cursor credentials. Open Cursor and try again.", needsAction: true)
        case .keychainUnavailable:
            UsageIssue(
                "Could not read Cursor credentials from the Keychain. Unlock your Mac and try again."
            )
        case .signInChanged:
            UsageIssue(
                "The Cursor account changed during the refresh. Refresh again to show the new account."
            )
        case .invalidDate:
            UsageIssue("The date on this Mac is not valid. Set the correct date and time.")
        }
    }

    /// Whether the previous observation may stay, as stale, while its owner is signed in.
    /// Usage that Cursor turned off no longer describes the account, so it goes.
    var keepsObservation: Bool {
        self != .usageDisabled
    }

    /// Maps a transport error. Cancellation is not a failure and is rethrown by callers first.
    init(transport error: any Error) {
        switch error as? HTTPError {
        case .offline: self = .offline
        case .timedOut: self = .timedOut
        case .responseTooLarge, .redirectRejected: self = .unexpectedResponse
        case .transport, nil: self = .network
        }
    }

    /// Maps a non-success HTTP status.
    init(status: Int, retryAfter: String?, now: Date) {
        switch status {
        case 401: self = .sessionRejected
        case 403: self = .accessDenied
        case 429:
            self = .rateLimited(
                retryAt: RetryAfter.delay(retryAfter, now: now).map { now.addingTimeInterval($0) })
        default: self = .httpStatus(status)
        }
    }
}

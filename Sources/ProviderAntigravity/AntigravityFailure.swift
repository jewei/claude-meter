import Foundation
import MeterDomain

/// Every way an Antigravity refresh can fail, with the message the user sees and the ownership
/// state that decides retention (`docs/providers/antigravity.md`).
enum AntigravityFailure: Error, Equatable, Sendable {
    case cliNotFound
    case cliSearchFailed
    case signedOut
    case launchFailed(detail: String?)
    case timedOut
    case commandFailed(detail: String?)
    case unexpectedResponse(detail: String?)
    case noQuota

    /// Whether the failure proves that no Antigravity login is active, so any saved observation
    /// must be dropped. Temporary failures return `.unknown`.
    var ownerStatus: OwnerStatus {
        switch self {
        case .cliNotFound, .signedOut: .signedOut
        case .cliSearchFailed, .launchFailed, .timedOut, .commandFailed, .unexpectedResponse,
            .noQuota:
            .unknown
        }
    }

    var issue: UsageIssue {
        switch self {
        case .cliNotFound:
            UsageIssue(
                "Install the Antigravity CLI (`agy`) so Claude Meter can read Antigravity usage.",
                needsAction: true)
        case .cliSearchFailed:
            UsageIssue("Could not look for the Antigravity CLI. Claude Meter will try again soon.")
        case .signedOut:
            UsageIssue(
                "Antigravity is not signed in. Run `agy` in Terminal to sign in.",
                needsAction: true)
        case .launchFailed:
            UsageIssue(
                "Could not start the Antigravity CLI. Check that `agy` runs in Terminal.",
                needsAction: true)
        case .timedOut:
            UsageIssue("Antigravity did not answer in time. Claude Meter will try again soon.")
        case .commandFailed:
            UsageIssue("Antigravity could not read usage. Claude Meter will try again soon.")
        case .unexpectedResponse:
            UsageIssue(
                "Antigravity returned an unexpected response. Claude Meter will try again soon.")
        case .noQuota:
            UsageIssue("Antigravity reported no usage limits. Claude Meter will try again soon.")
        }
    }

    /// Detail for Diagnostics only, never shown on the card.
    var diagnosticDetail: String? {
        switch self {
        case .launchFailed(let detail), .commandFailed(let detail),
            .unexpectedResponse(let detail):
            detail
        case .cliNotFound, .cliSearchFailed, .signedOut, .timedOut, .noQuota:
            nil
        }
    }
}

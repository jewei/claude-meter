import Foundation
import MeterDomain

/// Why one Claude account has no fresh reading. Owns every user-facing failure text.
///
/// The active Claude Code login (and the manual login) uses the provider-wide notices, which
/// name the fix. Other config dirs use shorter texts that say "for this account".
enum AccountFailure: Error, Equatable {
    case credentialsMissing
    case credentialsUnavailable
    case credentialsInvalid
    case credentialsExpired
    /// The credential was read, but the identity file could not be read now.
    case identityUnavailable
    case unauthorized
    case rateLimited(until: Date?)
    case invalidResponse
    case httpStatus(Int)
    case transport(String)
    /// The account, or the whole refresh, ran out of time.
    case timedOut
    /// The login changed while the request was in flight, so the response was discarded.
    case loginChanged
    case refreshDeferred
    case refreshFailed
    /// Manual mode has no stored login.
    case notConnected

    static let notConnectedMessage = "Connect Claude in Settings to read usage."
    static let rateLimitedMessage = "Anthropic is rate-limiting usage checks."

    init(_ failure: UsageFailure) {
        switch failure {
        case .rateLimited(let until): self = .rateLimited(until: until)
        case .unauthorized: self = .unauthorized
        case .httpStatus(let status): self = .httpStatus(status)
        case .invalidResponse: self = .invalidResponse
        case .transport(let reason): self = .transport(reason)
        }
    }

    init(_ failure: ManualLogin.Failure) {
        switch failure {
        case .missing: self = .notConnected
        case .invalid: self = .credentialsInvalid
        case .unavailable: self = .credentialsUnavailable
        case .expired: self = .credentialsExpired
        case .rejected: self = .unauthorized
        case .deferred: self = .refreshDeferred
        case .refreshFailed: self = .refreshFailed
        case .changed: self = .loginChanged
        }
    }

    /// The issue to show on the account's card.
    func issue(isActiveLogin: Bool) -> UsageIssue {
        switch self {
        case .credentialsMissing:
            isActiveLogin
                ? action("Claude Code isn't signed in — run `claude login` to restore Claude usage")
                : action("Credentials missing. Run claude login for this account.")
        case .credentialsUnavailable:
            UsageIssue(
                isActiveLogin
                    ? "Keychain is locked — unlock your Mac to refresh Claude usage"
                    : "Keychain is temporarily unavailable.")
        case .credentialsInvalid:
            isActiveLogin
                ? action(
                    "Claude Code credentials couldn't be read — run `claude login` to re-create them"
                )
                : action("Credentials invalid. Run claude login for this account.")
        case .credentialsExpired:
            isActiveLogin
                ? Self.signInExpired
                : action("Credentials expired. Run claude login for this account.")
        case .identityUnavailable:
            UsageIssue("Could not read Claude Code's account file. Retrying at the next refresh.")
        case .unauthorized:
            isActiveLogin
                ? Self.signInExpired
                : action("Sign in again with claude login for this account.")
        case .rateLimited(let until):
            UsageIssue(Self.rateLimitedMessage, retryAt: until)
        case .invalidResponse:
            UsageIssue("Claude returned an invalid usage response.")
        case .httpStatus(let status):
            UsageIssue("Anthropic usage check failed (HTTP \(status)).")
        case .transport(let reason):
            UsageIssue("Could not refresh Claude usage. \(reason)")
        case .timedOut:
            UsageIssue("The Claude usage check timed out.")
        case .loginChanged:
            UsageIssue("Claude Code sign-in changed during the usage check.")
        case .refreshDeferred, .refreshFailed:
            UsageIssue("Retrying the Claude Code sign-in…")
        case .notConnected:
            action(Self.notConnectedMessage)
        }
    }

    /// The account after this failure: the previous observation kept as stale while it
    /// belongs to the login in `status`, otherwise an unavailable account.
    func account(
        id: AccountID, name: String, prior: AccountUsage?, status: OwnerStatus,
        isActiveLogin: Bool, now: Date
    ) -> AccountUsage {
        let issue = issue(isActiveLogin: isActiveLogin)
        if let prior, prior.hasObservation, prior.belongs(to: status) {
            var kept = prior.retained(issue: issue, now: now)
            kept.name = name
            return kept
        }
        return .unavailable(
            id: id, name: name, issue: issue, attemptedAt: now, owner: status.signedInOwner)
    }

    private static let signInExpired = UsageIssue(
        "Claude Code sign-in expired — run `claude login` to restore Claude usage",
        needsAction: true)

    private func action(_ message: String) -> UsageIssue {
        UsageIssue(message, needsAction: true)
    }
}

extension OwnerStatus {
    /// The owner when signed in.
    var signedInOwner: AccountOwner? {
        if case .signedIn(let owner) = self { return owner }
        return nil
    }
}

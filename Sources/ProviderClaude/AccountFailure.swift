import Foundation
import MeterDomain

/// Why one Claude account has no fresh reading. Owns every user-facing failure text.
///
/// The advice depends on who can fix the problem (``Audience``): Claude Code for its active
/// login, Claude Code started with the account's config dir for other accounts, and a new
/// Connect in Settings for the manual login.
enum AccountFailure: Error, Equatable {
    case credentialsMissing
    case credentialsUnavailable
    case credentialsInvalid
    case credentialsExpired
    /// The credential was read, but the identity file could not be read now.
    case identityUnavailable
    /// HTTP 401 or 403, or a manual refresh token rejected with `invalid_grant`.
    case unauthorized
    case rateLimited(until: Date?)
    case invalidResponse
    case httpStatus(Int)
    case transport(String)
    /// The account, or the whole refresh, ran out of time.
    case timedOut
    /// The login changed while the request was in flight, so the response was discarded.
    case loginChanged
    /// Manual mode: waiting after earlier temporary refresh failures.
    case refreshDeferred
    /// Manual mode: a temporary token refresh failure, with its reason.
    case refreshFailed(String)
    /// Manual mode has no stored login.
    case notConnected

    /// Who reads the text, which decides the advice.
    enum Audience: Equatable, Sendable {
        /// Claude Code's active login.
        case activeLogin
        /// Another config dir, shown as a path that starts with `~/` when it is in the home
        /// folder, so that the advice signs in that dir and not the default one.
        case configDirectory(String)
        /// The app's own manual login. Claude Code commands cannot change it.
        case manual
    }

    static let notConnectedMessage = "Connect Claude in Settings to read usage."
    static let rateLimitedMessage = "Anthropic is rate-limiting usage checks."

    init(_ failure: UsageFailure) {
        switch failure {
        case .rateLimited(let until): self = .rateLimited(until: until)
        case .unauthorized, .forbidden: self = .unauthorized
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
        case .refreshFailed(let reason): self = .refreshFailed(reason)
        case .changed: self = .loginChanged
        }
    }

    /// The issue to show on the account's card.
    func issue(for audience: Audience) -> UsageIssue {
        switch audience {
        case .activeLogin: activeLoginIssue
        case .configDirectory(let path): configDirectoryIssue(command: Self.command(for: path))
        case .manual: manualIssue
        }
    }

    /// The account after this failure: the previous observation kept as stale while it
    /// belongs to the login in `status`, otherwise an unavailable account.
    func account(
        id: AccountID, name: String, prior: AccountUsage?, status: OwnerStatus,
        audience: Audience, now: Date
    ) -> AccountUsage {
        let issue = issue(for: audience)
        if let prior, prior.hasObservation, prior.belongs(to: status) {
            var kept = prior.retained(issue: issue, now: now)
            kept.name = name
            return kept
        }
        return .unavailable(
            id: id, name: name, issue: issue, attemptedAt: now, owner: status.signedInOwner)
    }

    private var activeLoginIssue: UsageIssue {
        switch self {
        case .credentialsMissing:
            action("Claude Code isn't signed in. Open Claude Code and run /login.")
        case .credentialsUnavailable:
            UsageIssue("Keychain is locked. Unlock your Mac to refresh Claude usage.")
        case .credentialsInvalid:
            action("Claude Code's credentials can't be read. Open Claude Code and run /login.")
        case .credentialsExpired:
            // Claude Code renews its token the next time it runs, so no sign-in is needed.
            UsageIssue("Claude Code's token expired. Open Claude Code once to renew it.")
        case .unauthorized:
            action("Anthropic rejected Claude Code's sign-in. Open Claude Code and run /login.")
        case .loginChanged:
            UsageIssue("Claude Code sign-in changed during the usage check.")
        default:
            sharedIssue
        }
    }

    private func configDirectoryIssue(command: String) -> UsageIssue {
        switch self {
        case .credentialsMissing:
            action("Not signed in. Run \(command), then /login.")
        case .credentialsUnavailable:
            UsageIssue("Keychain is temporarily unavailable.")
        case .credentialsInvalid:
            action("Credentials can't be read. Run \(command), then /login.")
        case .credentialsExpired:
            UsageIssue("Token expired. Run \(command) once to renew it.")
        case .unauthorized:
            action("Sign-in rejected. Run \(command), then /login.")
        case .loginChanged:
            UsageIssue("Claude Code sign-in changed during the usage check.")
        default:
            sharedIssue
        }
    }

    private var manualIssue: UsageIssue {
        switch self {
        case .credentialsMissing, .notConnected:
            action(Self.notConnectedMessage)
        case .credentialsUnavailable:
            UsageIssue("Keychain is locked. Unlock your Mac to refresh Claude usage.")
        case .credentialsInvalid:
            action("The saved Claude tokens can't be read. Connect again in Settings.")
        case .credentialsExpired, .unauthorized:
            action(
                "The saved Claude tokens no longer work. Connect again in Settings with new tokens."
            )
        case .loginChanged:
            UsageIssue("The Claude connection changed during the usage check.")
        default:
            sharedIssue
        }
    }

    /// Texts that give the same advice to every audience.
    private var sharedIssue: UsageIssue {
        switch self {
        case .identityUnavailable:
            UsageIssue("Could not read Claude Code's account file. Retrying at the next refresh.")
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
        case .refreshDeferred:
            UsageIssue("Retrying the Claude token refresh…")
        case .refreshFailed(let reason):
            UsageIssue("Could not refresh the Claude tokens. \(reason)")
        case .notConnected:
            action(Self.notConnectedMessage)
        case .credentialsMissing, .credentialsUnavailable, .credentialsInvalid,
            .credentialsExpired, .unauthorized, .loginChanged:
            // Every audience words these itself.
            UsageIssue("Claude usage is unavailable.")
        }
    }

    /// The shell command that opens Claude Code with the config dir at `path`. The default
    /// dir needs no variable. The tilde stays outside quotes so that the shell expands it.
    static func command(for path: String) -> String {
        if path == "~/.claude" { return "`claude`" }
        let (prefix, rest) = path.hasPrefix("~/") ? ("~/", String(path.dropFirst(2))) : ("", path)
        let isPlain = rest.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)
        }
        let quoted = isPlain ? rest : "'" + rest.replacing("'", with: #"'\''"#) + "'"
        return "`CLAUDE_CONFIG_DIR=\(prefix)\(quoted) claude`"
    }

    /// A text that asks the user to act.
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

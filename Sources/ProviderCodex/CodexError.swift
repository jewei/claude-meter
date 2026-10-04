import Foundation
import MeterDomain

/// Every expected Codex failure. Each message is a short sentence that says what the user
/// can do.
enum CodexError: Error, Equatable, LocalizedError, Sendable {
    // auth.json
    case authFileMissing
    case authFileUnreadable
    case authFileInvalid
    case missingTokens
    case apiKeyOnly
    case accessTokenExpired
    case homeMissing

    // The usage request
    case loginRequired
    case httpStatus(Int, retryAt: Date?)
    case network(String)
    case unexpectedResponse
    case noUsageData

    // App-server recovery
    case cliNotFound
    /// The search for the `codex` command did not finish in time.
    case cliSearchFailed
    case appServerLaunchFailed
    case appServerTimedOut(step: String)
    case appServerFailed(String)
    case appServerStopped
    case appServerUnexpected
    /// `account/read` reported no account: Codex has no login for the home.
    case notSignedIn
    /// Recovery failed after the direct path sent the login to it. `message` is the one
    /// sentence for the card; `reasons` holds both raw reasons, for Diagnostics.
    case recoveryFailed(message: String, reasons: String, needsAction: Bool)

    // The whole account
    case signInChanged
    case timedOut

    var errorDescription: String? {
        switch self {
        case .authFileMissing:
            "Codex auth file not found."
        case .authFileUnreadable:
            "Could not read Codex auth file. Check that your user can read it."
        case .authFileInvalid:
            "Could not decode Codex auth file. Run `codex login`."
        case .missingTokens:
            "Codex auth file has no ChatGPT OAuth tokens. Run `codex login`."
        case .apiKeyOnly:
            "Codex API-key auth has no ChatGPT subscription quota. Sign in with ChatGPT in Codex."
        case .accessTokenExpired:
            "Codex access token needs renewal by Codex. Open Codex or run `codex login`."
        case .homeMissing:
            "Codex home folder not found. Run `codex login`, or check the folder in Settings."
        case .loginRequired:
            "Codex login required. Run `codex login`."
        case .httpStatus(let status, _):
            "Codex usage request failed (HTTP \(status)). Refresh again later."
        case .network(let reason):
            "Could not reach Codex. \(reason) Refresh again later."
        case .unexpectedResponse:
            "Codex sent a usage response in an unknown format. Update Claude Meter, then refresh."
        case .noUsageData:
            "Codex returned no usage windows. Refresh again later."
        case .cliNotFound:
            "Codex CLI not found. Install Codex, then refresh."
        case .cliSearchFailed:
            "Could not look for the Codex CLI in time. Refresh again."
        case .appServerLaunchFailed:
            "Codex CLI could not start. Reinstall Codex, then refresh."
        case .appServerTimedOut(let step):
            "Codex CLI timed out during \(step). Refresh again."
        case .appServerFailed(let reason):
            "Codex CLI request failed: \(reason)"
        case .appServerStopped:
            "Codex CLI stopped before it answered. Check that `codex` runs in Terminal, then refresh."
        case .appServerUnexpected:
            "Codex CLI sent a response that Claude Meter cannot read. Update Codex and Claude Meter."
        case .notSignedIn:
            "Codex is not signed in. Run `codex login`."
        case .recoveryFailed(let message, _, _):
            message
        case .signInChanged:
            "Codex sign-in changed or could not be verified. Refresh again."
        case .timedOut:
            "Codex did not answer in time. Refresh again later."
        }
    }

    /// Only the user can fix it, for example by signing in again.
    var needsAction: Bool {
        switch self {
        case .authFileInvalid, .missingTokens, .apiKeyOnly, .homeMissing, .loginRequired,
            .cliNotFound, .appServerLaunchFailed, .notSignedIn:
            true
        case .recoveryFailed(_, _, let needsAction):
            needsAction
        default:
            false
        }
    }

    /// Whether `codex app-server` can fix it by renewing or finding the sign-in.
    ///
    /// Network failures, other HTTP statuses, unknown formats, and API-key auth never start
    /// recovery: Codex cannot fix them, and the original error is more useful.
    var startsRecovery: Bool {
        switch self {
        case .authFileMissing, .authFileUnreadable, .authFileInvalid, .missingTokens,
            .accessTokenExpired, .loginRequired:
            true
        default:
            false
        }
    }

    /// Both raw reasons of a failed recovery, for Diagnostics. Nil for other errors.
    var reasons: String? {
        if case .recoveryFailed(_, let reasons, _) = self { return reasons }
        return nil
    }

    /// A failed recovery after `direct` sent the login to it.
    ///
    /// The card shows one sentence. The recovery reason shows when the login has no auth file
    /// (only Codex can read it), when only the user can fix the recovery (such as a missing
    /// CLI), or when Codex answered without usage. Otherwise the direct reason shows, because
    /// it names the login problem and its fix.
    static func combining(_ recovery: any Error, direct: CodexError) -> CodexError {
        let recoveryError = recovery as? CodexError
        let recoveryNeedsAction = recoveryError?.needsAction ?? false
        let showsRecovery =
            direct == .authFileMissing || recoveryNeedsAction || recoveryError == .noUsageData
        let shown = showsRecovery ? recovery.localizedDescription : direct.localizedDescription
        return .recoveryFailed(
            message: shown,
            reasons: "Usage request: \(direct.localizedDescription) "
                + "Codex app-server: \(recovery.localizedDescription)",
            needsAction: recoveryNeedsAction || direct.needsAction)
    }

    var issue: UsageIssue {
        let retryAt: Date? =
            if case .httpStatus(_, let retryAt) = self { retryAt } else { nil }
        return UsageIssue(
            errorDescription ?? "Codex failed.", retryAt: retryAt, needsAction: needsAction)
    }
}

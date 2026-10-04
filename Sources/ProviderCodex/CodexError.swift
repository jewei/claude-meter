import Foundation
import MeterDomain

/// Every expected Codex failure. Each message is a short sentence that says what the user
/// can do.
enum CodexError: Error, Equatable, LocalizedError, Sendable {
    // auth.json
    case authFileMissing
    /// The auth file cannot be read, for example because of its permissions.
    case authFileUnreadable
    /// The read of the auth file timed out or found no free thread. It can pass.
    case authFileTimedOut
    case authFileInvalid
    case missingTokens
    case apiKeyOnly
    case accessTokenExpired
    case homeMissing

    // The usage request
    case loginRequired
    /// HTTP 429. Requests for the same login wait until `retryAt` (``RateLimitHold``).
    case rateLimited(retryAt: Date?)
    case httpStatus(Int)
    case network(String)
    case unexpectedResponse
    case noUsageData

    // App-server recovery
    case cliNotFound
    /// The search for the `codex` command did not finish in time.
    case cliSearchFailed
    // `detail` is what the system or the child said, redacted, for Diagnostics only. The
    // card never shows it (``detail``).
    case appServerLaunchFailed(detail: String?)
    case appServerTimedOut(step: String)
    case appServerFailed(String)
    /// The child ended before it answered `step`.
    case appServerStopped(step: String, detail: String?)
    case appServerUnexpected(detail: String?)
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
        case .authFileTimedOut:
            "Reading the Codex auth file took too long. Claude Meter will try again soon."
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
        case .rateLimited:
            "Codex limited the number of requests. Claude Meter will try again later."
        case .httpStatus(let status):
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
            "Codex CLI request failed: \(Self.sentence(reason)). Refresh again later."
        case .appServerStopped(let step, _) where step == CodexAppServerSession.firstStep:
            // A Codex without `app-server`, or one that cannot run, ends at once.
            "Codex CLI stopped before it answered. Update Codex, then refresh."
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

    /// Server text without its final period and spaces, to put inside a sentence.
    private static func sentence(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "no details" : text
    }

    /// What the system or the child said about an app-server failure, for Diagnostics: the
    /// last line of its standard error, or the launch error. Nil for other errors.
    var detail: String? {
        switch self {
        case .appServerLaunchFailed(let detail), .appServerStopped(_, let detail),
            .appServerUnexpected(let detail):
            detail
        default:
            nil
        }
    }

    /// This failure with `detail` added, when it is a stop or an unreadable answer without
    /// one. Other errors stay as they are.
    func adding(detail: String?) -> CodexError {
        switch self {
        case .appServerStopped(let step, nil): .appServerStopped(step: step, detail: detail)
        case .appServerUnexpected(nil): .appServerUnexpected(detail: detail)
        default: self
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
    /// An auth file that cannot be read now never starts recovery either: it names no owner,
    /// so the answer could never be verified (``CodexLogin/route``).
    var startsRecovery: Bool {
        switch self {
        case .authFileMissing, .authFileInvalid, .missingTokens, .accessTokenExpired,
            .loginRequired:
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
        var reasons =
            "Usage request: \(direct.localizedDescription) "
            + "Codex app-server: \(recovery.localizedDescription)"
        if let detail = recoveryError?.detail { reasons += " Details: \(detail)" }
        return .recoveryFailed(
            message: shown, reasons: reasons,
            needsAction: recoveryNeedsAction || direct.needsAction)
    }

    var issue: UsageIssue {
        let retryAt: Date? =
            if case .rateLimited(let retryAt) = self { retryAt } else { nil }
        return UsageIssue(
            errorDescription ?? "Codex failed.", retryAt: retryAt, needsAction: needsAction)
    }
}

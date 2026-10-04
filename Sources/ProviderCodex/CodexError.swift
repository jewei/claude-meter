import Foundation
import MeterDomain

/// Every expected Codex failure. Each message says what the user can do.
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
    case appServerLaunchFailed
    case appServerTimedOut(step: String)
    case appServerFailed(String)
    case appServerStopped
    case appServerUnexpected
    /// `account/read` reported no account: Codex has no login for the home.
    case notSignedIn
    case allSourcesFailed(appServer: String, direct: String, needsAction: Bool)

    // The whole account
    case signInChanged
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .authFileMissing:
            "Codex auth file not found; using Codex CLI if available."
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
        case .appServerLaunchFailed:
            "Codex CLI could not start. Reinstall Codex, then refresh."
        case .appServerTimedOut(let step):
            "Codex CLI timed out during \(step). Refresh again."
        case .appServerFailed(let reason):
            "Codex CLI request failed: \(reason)"
        case .appServerStopped:
            "Codex CLI stopped before it answered. Update Codex, then refresh."
        case .appServerUnexpected:
            "Codex CLI returned an unexpected response. Update Codex, then refresh."
        case .notSignedIn:
            "Codex is not signed in. Run `codex login`."
        case .allSourcesFailed(let appServer, let direct, _):
            "Codex App Server failed: \(appServer) Direct OAuth failed: \(direct)"
        case .signInChanged:
            "Codex sign-in changed or could not be verified. Refresh again."
        case .timedOut(let seconds):
            "Codex did not answer within \(seconds) seconds. Refresh again later."
        }
    }

    /// Only the user can fix it, for example by signing in again.
    var needsAction: Bool {
        switch self {
        case .authFileInvalid, .missingTokens, .apiKeyOnly, .homeMissing, .loginRequired,
            .cliNotFound, .appServerLaunchFailed, .notSignedIn:
            true
        case .allSourcesFailed(_, _, let needsAction):
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

    /// A failed recovery after `direct` sent the login to it.
    static func combining(_ recovery: any Error, direct: CodexError) -> CodexError {
        let recoveryNeedsAction = (recovery as? CodexError)?.needsAction ?? false
        return .allSourcesFailed(
            appServer: recovery.localizedDescription, direct: direct.localizedDescription,
            needsAction: recoveryNeedsAction || direct.needsAction)
    }

    var issue: UsageIssue {
        let retryAt: Date? =
            if case .httpStatus(_, let retryAt) = self { retryAt } else { nil }
        return UsageIssue(
            errorDescription ?? "Codex failed.", retryAt: retryAt, needsAction: needsAction)
    }
}

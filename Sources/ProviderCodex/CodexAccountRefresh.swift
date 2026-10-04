import Foundation
import MeterDomain
import MeterPlatform

/// Refreshes one Codex home.
///
/// 1. Read `auth.json` once, for the credentials and the owner together.
/// 2. Send the usage request, or start app-server recovery when the request cannot work.
/// 3. Read the owner again. A login that changed during the request discards the response.
///
/// Every observation has an owner, and every failure carries the owner status that
/// ``AccountUsage/belongs(to:)`` needs to decide whether the previous observation stays.
struct CodexAccountRefresh: Sendable {
    /// Where an observation came from, for Diagnostics.
    enum Source: String, Sendable {
        case direct = "Usage request"
        case recovery = "Codex app-server"
    }

    struct Outcome: Sendable {
        enum Result: Sendable {
            case observed(CodexQuota, owner: AccountOwner)
            /// `status` is the latest owner status, for retention of the previous observation.
            case failed(CodexError, status: OwnerStatus)
        }

        var result: Result
        var source: Source?
        /// What the auth file held before the request, for Diagnostics.
        var login: String?

        /// A home that did not finish by the fetch deadline. The text names no number of
        /// seconds, because a home that started late had less time.
        static let timedOut = Outcome(result: .failed(.timedOut, status: .unknown))
    }

    /// What Codex itself said about the login during recovery.
    enum CodexReport: Equatable, Sendable {
        /// `account/read` named this ChatGPT account.
        case signedIn(AccountOwner)
        /// `account/read` reported no account, or an API key.
        case signedOut
        /// No Codex CLI was found, so no keyring login can exist for the app.
        case noCLI
    }

    /// One request or recovery, before the owner is checked again.
    struct Attempt: Sendable {
        var quota: Result<CodexQuota, CodexError>
        var source: Source
        var report: CodexReport?
    }

    let api: CodexUsageAPI
    let recovery: any CodexRecovery
    let environment: [String: String]
    let fileReadLimit: Duration
    let now: @Sendable () -> Date

    /// Throws only `CancellationError`.
    func run(_ home: CodexHome) async throws -> Outcome {
        let before = try await CodexLogin.read(home, timeout: fileReadLimit)
        switch before {
        case .apiKey:
            return Outcome(
                result: .failed(.apiKeyOnly, status: .signedOut), login: before.summary)
        case .noHome:
            return Outcome(
                result: .failed(.homeMissing, status: .signedOut), login: before.summary)
        case .chatGPT, .missing, .noTokens, .invalid, .unreadable:
            break
        }
        let attempt = try await obtain(home, login: before)
        let after = try await CodexLogin.read(home, timeout: fileReadLimit)
        return Outcome(
            result: Self.result(of: attempt, before: before, after: after),
            source: attempt.source, login: before.summary)
    }

    /// The outcome of `attempt` once the owner was read again.
    static func result(
        of attempt: Attempt, before: CodexLogin, after: CodexLogin
    ) -> Outcome.Result {
        switch attempt.quota {
        case .failure(let error):
            return .failed(error, status: status(after: after, error: error, attempt.report))
        case .success(let quota):
            if let owner = verifiedOwner(
                before: before, after: after, source: attempt.source, report: attempt.report)
            {
                return .observed(quota, owner: owner)
            }
            let error: CodexError = after == .unreadable ? .authFileUnreadable : .signInChanged
            return .failed(error, status: status(after: after, error: error, attempt.report))
        }
    }

    /// The owner status after a failure.
    ///
    /// API-key auth, and a Codex that reports no account, are signed out whatever the file
    /// says. Without an auth file, Codex's own report decides; without one it is unknown.
    /// Otherwise the file decides.
    static func status(after: CodexLogin, error: CodexError, _ report: CodexReport?) -> OwnerStatus
    {
        if error == .apiKeyOnly || report == .signedOut { return .signedOut }
        guard after == .missing else { return after.ownerStatus }
        switch report {
        case .signedIn(let owner): return .signedIn(owner)
        case .noCLI: return .signedOut
        case .signedOut, nil: return .unknown
        }
    }

    /// The owner of a new observation, or nil when the owner changed or cannot be named.
    ///
    /// A ChatGPT identity must stay the same, and a direct request must keep its exact owner.
    /// Recovery from a login without an identity takes the owner that the file names after it,
    /// because Codex can rewrite the file while it renews the tokens. Recovery without an auth
    /// file before and after takes the account that Codex reported. A file that cannot be read
    /// or parsed after the request names no owner, so the response is discarded.
    static func verifiedOwner(
        before: CodexLogin, after: CodexLogin, source: Source, report: CodexReport?
    ) -> AccountOwner? {
        let unchanged = after.owner == before.owner ? after.owner : nil
        if case .identity = before.owner { return unchanged }
        switch (source, after) {
        case (.direct, _):
            return unchanged
        case (.recovery, .chatGPT), (.recovery, .noTokens):
            return after.owner
        case (.recovery, .missing):
            guard before == .missing, case .signedIn(let owner) = report else { return nil }
            return owner
        case (.recovery, .apiKey), (.recovery, .noHome), (.recovery, .invalid),
            (.recovery, .unreadable):
            return nil
        }
    }

    // MARK: - Work

    private func obtain(_ home: CodexHome, login: CodexLogin) async throws -> Attempt {
        guard case .chatGPT(let credentials) = login else {
            guard let reason = login.recoveryReason else {
                return Attempt(quota: .failure(.apiKeyOnly), source: .direct)
            }
            return try await recover(home, directError: reason)
        }
        let now = now()
        if credentials.needsRenewal(at: now) {
            return try await recover(home, directError: .accessTokenExpired)
        }
        do {
            return Attempt(
                quota: .success(try await api.quota(with: credentials, now: now)),
                source: .direct)
        } catch let error as CodexError where error.startsRecovery {
            return try await recover(home, directError: error)
        } catch let error as CodexError {
            return Attempt(quota: .failure(error), source: .direct)
        }
    }

    private func recover(_ home: CodexHome, directError: CodexError) async throws -> Attempt {
        let reply: CodexRecoveryReply
        do {
            reply = try await recovery.recover(
                home, environment: CodexEnvironment.scoped(environment, home: home))
        } catch is CancellationError {
            throw CancellationError()
        } catch CodexError.apiKeyOnly {
            return Attempt(quota: .failure(.apiKeyOnly), source: .recovery, report: .signedOut)
        } catch {
            let report: CodexReport? = error as? CodexError == .cliNotFound ? .noCLI : nil
            return Attempt(
                quota: .failure(.combining(error, direct: directError)), source: .recovery,
                report: report)
        }
        if CodexAppServerResult.authMode(account: reply.account) == .apiKey {
            return Attempt(quota: .failure(.apiKeyOnly), source: .recovery, report: .signedOut)
        }
        if CodexAppServerResult.reportsNoAccount(reply.account) {
            return Attempt(quota: .failure(.notSignedIn), source: .recovery, report: .signedOut)
        }
        let report = CodexAppServerResult.owner(account: reply.account).map(CodexReport.signedIn)
        do {
            let quota = try CodexAppServerResult.quota(
                account: reply.account, rateLimits: reply.rateLimits, now: now())
            return Attempt(quota: .success(quota), source: .recovery, report: report)
        } catch {
            return Attempt(
                quota: .failure(.combining(error, direct: directError)), source: .recovery,
                report: report)
        }
    }
}

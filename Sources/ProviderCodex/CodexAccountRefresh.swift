import Foundation
import MeterDomain
import MeterPlatform

/// Refreshes one Codex home.
///
/// 1. Read `auth.json` once, for the credentials and the owner together.
/// 2. Send the usage request, or start app-server recovery when the request cannot work.
/// 3. Read the owner again. A login that changed during the request discards the response.
struct CodexAccountRefresh: Sendable {
    /// Where an observation came from, for Diagnostics.
    enum Source: String, Sendable {
        case direct = "Usage request"
        case recovery = "Codex app-server"
    }

    struct Outcome: Sendable {
        enum Result: Sendable {
            case observed(CodexQuota, owner: AccountOwner?)
            /// `status` is the latest owner status, for retention of the previous observation.
            case failed(CodexError, status: OwnerStatus)
        }

        var result: Result
        var source: Source?
        /// What the auth file held before the request, for Diagnostics.
        var login: String?

        static func timedOut(after limit: Duration) -> Outcome {
            let seconds = Int(limit.timeInterval.rounded())
            return Outcome(result: .failed(.timedOut(seconds: seconds), status: .unknown))
        }
    }

    let api: CodexUsageAPI
    let recovery: any CodexRecovery
    let environment: [String: String]
    let fileReadLimit: Duration
    let now: @Sendable () -> Date

    /// Throws only `CancellationError`.
    func run(_ home: CodexHome) async throws -> Outcome {
        let before = try await CodexLogin.read(home, timeout: fileReadLimit)
        if before == .apiKey {
            return Outcome(
                result: .failed(.apiKeyOnly, status: .signedOut), login: before.summary)
        }
        let (attempt, source) = try await obtain(home, login: before)
        let after = try await CodexLogin.read(home, timeout: fileReadLimit)
        let result: Outcome.Result
        switch attempt {
        case .failure(let error):
            result = .failed(error, status: after.ownerStatus)
        case .success(let quota):
            if let owner = Self.verifiedOwner(before: before, after: after, source: source) {
                result = .observed(quota, owner: owner.value)
            } else {
                result = .failed(.signInChanged, status: after.ownerStatus)
            }
        }
        return Outcome(result: result, source: source, login: before.summary)
    }

    private func obtain(
        _ home: CodexHome, login: CodexLogin
    ) async throws -> (Result<CodexQuota, CodexError>, Source) {
        let directError: CodexError
        switch login {
        case .chatGPT(let credentials):
            let now = now()
            if credentials.needsRenewal(at: now) {
                directError = .accessTokenExpired
            } else {
                do {
                    return (.success(try await api.quota(with: credentials, now: now)), .direct)
                } catch let error as CodexError where error.startsRecovery {
                    directError = error
                } catch let error as CodexError {
                    return (.failure(error), .direct)
                }
            }
        case .apiKey:
            return (.failure(.apiKeyOnly), .direct)
        case .missing:
            directError = .authFileMissing
        case .unusable(let error, _):
            directError = error
        case .unreadable:
            directError = .authFileUnreadable
        }
        return (try await recover(home, directError: directError), .recovery)
    }

    private func recover(
        _ home: CodexHome, directError: CodexError
    ) async throws -> Result<CodexQuota, CodexError> {
        do {
            let reply = try await recovery.recover(
                home, environment: CodexEnvironment.scoped(environment, home: home))
            if CodexAppServerResult.authMode(account: reply.account) == .apiKey {
                return .failure(.apiKeyOnly)
            }
            return .success(
                try CodexAppServerResult.quota(
                    account: reply.account, rateLimits: reply.rateLimits, now: now()))
        } catch is CancellationError {
            throw CancellationError()
        } catch CodexError.apiKeyOnly {
            return .failure(.apiKeyOnly)
        } catch {
            let recoveryNeedsAction = (error as? CodexError)?.needsAction ?? false
            return .failure(
                .allSourcesFailed(
                    appServer: error.localizedDescription,
                    direct: directError.localizedDescription,
                    needsAction: recoveryNeedsAction || directError.needsAction))
        }
    }

    /// A verified owner; `value` is nil for a login without an auth file.
    struct VerifiedOwner: Equatable {
        let value: AccountOwner?
    }

    /// The owner of a new observation, or nil when the login changed during the request.
    ///
    /// A ChatGPT identity must stay the same. A direct request must keep its exact owner.
    /// Recovery from a login without an identity is accepted with the owner it left behind,
    /// because Codex can rewrite the auth file while it renews the tokens. Recovery without a
    /// readable file is accepted, without an owner, only when the file state did not change.
    static func verifiedOwner(
        before: CodexLogin, after: CodexLogin, source: Source
    ) -> VerifiedOwner? {
        let unchanged = after.owner == before.owner ? VerifiedOwner(value: after.owner) : nil
        if case .identity = before.owner { return unchanged }
        switch (source, after) {
        case (.direct, _):
            return unchanged
        case (.recovery, .chatGPT), (.recovery, .unusable):
            return VerifiedOwner(value: after.owner)
        case (.recovery, .missing), (.recovery, .unreadable):
            return after == before ? VerifiedOwner(value: nil) : nil
        case (.recovery, .apiKey):
            return nil
        }
    }
}

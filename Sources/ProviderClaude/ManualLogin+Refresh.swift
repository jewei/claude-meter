import Foundation
import MeterDomain
import MeterPlatform

/// Token refreshes of the manual login: when a refresh goes out, how callers share one, and
/// what a rotation changes. ``ManualRefreshPolicy`` decides what may go out after failures.
extension ManualLogin {
    /// What the token refreshes of one generation know. Only this file reads or changes its
    /// fields; ``ManualLogin`` starts it over when a Connect is stored or a Disconnect starts.
    struct RefreshState: Sendable {
        /// Token requests in flight, by the refresh token that they spend.
        fileprivate var running: [String: Task<ManualCredential, any Error>] = [:]
        fileprivate var policy = ManualRefreshPolicy()
        /// Tokens that a Connect got from the token endpoint but has not stored, by the
        /// refresh token that the user pasted. The server spent that token when it rotated
        /// it, so a retry of Connect with the same pasted tokens must use these instead.
        fileprivate var pendingRotation: (pasted: String, credential: ManualCredential)?
    }

    /// A credential that does not expire within 60 s, refreshed first when needed. Throws
    /// ``Failure/rejected`` without a request for a connection that the server rejected, and
    /// ``Failure/changed`` when a Disconnect or a Connect came during the refresh or its save.
    func usable() async throws -> ManualCredential {
        let credential = try await current()
        guard !refreshState.policy.isRejected(connectionID: credential.connectionID) else {
            throw Failure.rejected
        }
        guard credential.isExpired(at: now()) else { return credential }
        return try await refreshed(from: credential)
    }

    /// One refresh after the server rejected `credential` with HTTP 401. Throws
    /// ``Failure/changed`` without a request when `credential` is no longer the stored login.
    func refreshedAfterRejection(of credential: ManualCredential) async throws -> ManualCredential {
        try await refreshed(from: credential)
    }

    /// Stops all requests for the connection of `credential` until the next Connect: the
    /// server rejected its tokens, and a refresh did not help.
    func markRejected(_ credential: ManualCredential) {
        guard refreshState.policy.rejectConnection(credential.connectionID) else { return }
        log.notice("Manual Claude tokens were rejected; waiting for a new Connect")
    }

    /// The rotation that an earlier Connect got for the refresh token the user pasted.
    func pendingRotation(for pastedRefreshToken: String) -> ManualCredential? {
        guard let pending = refreshState.pendingRotation, pending.pasted == pastedRefreshToken
        else { return nil }
        return pending.credential
    }

    /// Forgets the pending rotation of `pastedRefreshToken`, after the server rejected it.
    func discardPendingRotation(for pastedRefreshToken: String) {
        if refreshState.pendingRotation?.pasted == pastedRefreshToken {
            refreshState.pendingRotation = nil
        }
    }

    /// Refreshes tokens that are not stored yet, during Connect. Shares an in-flight request
    /// for the same refresh token and ignores the backoff. Stores nothing in the Keychain, but
    /// keeps the rotation for `pastedRefreshToken` until a Connect stores it. A Disconnect or a
    /// stored Connect during the request forgets the rotation and throws ``Failure/changed``.
    func refreshedCandidate(_ candidate: ManualCredential, pastedRefreshToken: String)
        async throws -> ManualCredential
    {
        guard let refreshToken = candidate.refreshToken else { throw Failure.expired }
        let startGeneration = generation
        switch await sharedRefresh(candidate, refreshToken: refreshToken).result {
        case .success(var fresh):
            guard generation == startGeneration else { throw Failure.changed }
            // The shared request may have started for the stored connection.
            fresh.connectionID = candidate.connectionID
            refreshState.pendingRotation = (pastedRefreshToken, fresh)
            return fresh
        case .failure(Failure.rejected):
            discardPendingRotation(for: pastedRefreshToken)
            throw Failure.rejected
        case .failure(let error):
            throw error
        }
    }

    private func refreshed(from used: ManualCredential) async throws -> ManualCredential {
        try ensureCurrent(used)
        // Another caller already rotated this connection's tokens.
        if let latest, latest.accessToken != used.accessToken, !latest.isExpired(at: now()) {
            return latest
        }
        guard let refreshToken = used.refreshToken else { throw Failure.expired }
        try refreshState.policy.checkRefresh(refreshToken, now: now())

        let startGeneration = generation
        let (result, isFirst) = await sharedRefresh(used, refreshToken: refreshToken)
        guard generation == startGeneration else { throw Failure.changed }
        switch result {
        case .success(var fresh):
            // The shared request may have started for a Connect of the same refresh token.
            fresh.connectionID = used.connectionID
            refreshState.policy.recordSuccess()
            await adopt(fresh, generation: startGeneration)
            // A Disconnect or a stored Connect during the save: the tokens must not go out.
            guard generation == startGeneration, !isDisconnected else { throw Failure.changed }
            return fresh
        case .failure(Failure.rejected):
            refreshState.policy.rejectRefreshToken(refreshToken)
            if isFirst { log.notice("Manual Claude refresh token was rejected") }
            throw Failure.rejected
        case .failure(let error):
            if isFirst {
                refreshState.policy.recordTemporaryFailure(now: now())
                log.warning("Manual Claude token refresh failed: \(error.localizedDescription)")
            }
            throw error
        }
    }

    /// Joins the in-flight refresh of `refreshToken`, or starts one. `isFirst` is true for the
    /// one caller that sees the request finish first, so outcomes are recorded once.
    private func sharedRefresh(
        _ credential: ManualCredential, refreshToken: String
    ) async -> (result: Result<ManualCredential, any Error>, isFirst: Bool) {
        let task: Task<ManualCredential, any Error>
        if let running = refreshState.running[refreshToken] {
            task = running
        } else {
            let refresher = refresher
            task = Task {
                do {
                    return try await refresher.refresh(credential, using: refreshToken)
                } catch TokenRefresher.Failure.rejected {
                    throw Failure.rejected
                } catch TokenRefresher.Failure.failed(let reason) {
                    throw Failure.refreshFailed(reason)
                }
            }
            refreshState.running[refreshToken] = task
        }
        let result = await task.result
        let isFirst = refreshState.running[refreshToken] == task
        if isFirst { refreshState.running[refreshToken] = nil }
        return (result, isFirst)
    }
}

import Foundation
import MeterDomain
import MeterPlatform

/// Token refreshes of the manual login: when a refresh goes out, how callers share one, and
/// what a rotation changes. ``ManualRefreshPolicy`` decides what may go out after failures.
extension ManualLogin {
    /// A credential that does not expire within 60 s, refreshed first when needed. Throws
    /// ``Failure/rejected`` without a request for a connection that the server rejected.
    func usable() async throws -> ManualCredential {
        let credential = try await current()
        guard !policy.isRejected(connectionID: credential.connectionID) else {
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
        guard policy.rejectConnection(credential.connectionID) else { return }
        log.notice("Manual Claude tokens were rejected; waiting for a new Connect")
    }

    /// The rotation that an earlier Connect got for the refresh token the user pasted.
    func pendingRotation(for pastedRefreshToken: String) -> ManualCredential? {
        guard let pendingRotation, pendingRotation.pasted == pastedRefreshToken else { return nil }
        return pendingRotation.credential
    }

    /// Forgets the pending rotation of `pastedRefreshToken`, after the server rejected it.
    func discardPendingRotation(for pastedRefreshToken: String) {
        if pendingRotation?.pasted == pastedRefreshToken { pendingRotation = nil }
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
            pendingRotation = (pastedRefreshToken, fresh)
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
        try policy.checkRefresh(refreshToken, now: now())

        let startGeneration = generation
        let (result, isFirst) = await sharedRefresh(used, refreshToken: refreshToken)
        guard generation == startGeneration else { throw Failure.changed }
        switch result {
        case .success(var fresh):
            // The shared request may have started for a Connect of the same refresh token.
            fresh.connectionID = used.connectionID
            if latest?.connectionID == used.connectionID, latest?.accessToken != fresh.accessToken {
                // In memory at once, so that no other caller sends the rotated refresh token.
                latest = fresh
                policy.recordSuccess()
                await persist(fresh, generation: startGeneration)
            }
            return fresh
        case .failure(Failure.rejected):
            policy.rejectRefreshToken(refreshToken)
            if isFirst { log.notice("Manual Claude refresh token was rejected") }
            throw Failure.rejected
        case .failure(let error):
            if isFirst {
                policy.recordTemporaryFailure(now: now())
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
        if let running = refreshes[refreshToken] {
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
            refreshes[refreshToken] = task
        }
        let result = await task.result
        let isFirst = refreshes[refreshToken] == task
        if isFirst { refreshes[refreshToken] = nil }
        return (result, isFirst)
    }
}

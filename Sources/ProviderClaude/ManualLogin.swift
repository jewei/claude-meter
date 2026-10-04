import Foundation
import MeterDomain
import MeterPlatform

/// Owns the manual login: loads it, refreshes it, and stores each rotation.
///
/// - A token is refreshed when it expires within 60 s, and once after HTTP 401.
/// - Concurrent callers with the same refresh token share one token request.
/// - Connect and disconnect bump a generation. A refresh that started before cannot commit,
///   save, or change any state afterwards.
/// - A refresh token rejected with `invalid_grant` is not sent again. Temporary failures back
///   off for 5 minutes, doubling up to 6 hours.
actor ManualLogin {
    enum Failure: Error, Equatable {
        /// No manual login is stored.
        case missing
        case invalid
        case unavailable(String)
        /// The token expired and there is no refresh token.
        case expired
        case rejected
        /// Waiting after earlier temporary refresh failures.
        case deferred
        case refreshFailed(String)
        /// Disconnected or reconnected while the work was in progress.
        case changed
    }

    static let backoffBase: TimeInterval = 5 * 60
    static let backoffLimit: TimeInterval = 6 * 60 * 60

    private let vault: ManualCredentialVault
    private let refresher: TokenRefresher
    private let now: @Sendable () -> Date
    private let log = Log(.claude)

    private var generation: UInt64 = 0
    private var writeSequence: UInt64 = 0
    /// The newest known credential of the stored connection, including unsaved rotations.
    private var latest: ManualCredential?
    private var refreshes: [String: Task<ManualCredential, any Error>] = [:]
    private var rejectedRefreshToken: String?
    private var transientFailures = 0
    private var backoffUntil: Date?

    init(
        vault: ManualCredentialVault, refresher: TokenRefresher, now: @escaping @Sendable () -> Date
    ) {
        self.vault = vault
        self.refresher = refresher
        self.now = now
    }

    /// The stored login, or a newer in-memory rotation of the same connection. A locked
    /// Keychain falls back to the in-memory credential. Throws ``Failure``.
    func current() async throws -> ManualCredential {
        let startGeneration = generation
        let read = try await vault.load()
        guard generation == startGeneration else {
            guard let latest else { throw Failure.missing }
            return latest
        }
        switch read {
        case .found(let stored):
            if let latest, latest.connectionID == stored.connectionID { return latest }
            latest = stored
            return stored
        case .missing:
            latest = nil
            throw Failure.missing
        case .invalid:
            throw Failure.invalid
        case .unavailable(let reason):
            guard let latest else { throw Failure.unavailable(reason) }
            return latest
        }
    }

    /// A credential that does not expire within 60 s, refreshed first when needed.
    func usable() async throws -> ManualCredential {
        let credential = try await current()
        guard credential.isExpired(at: now()) else { return credential }
        return try await refreshed(from: credential)
    }

    /// One refresh after the server rejected `credential` with HTTP 401.
    func refreshedAfterRejection(of credential: ManualCredential) async throws -> ManualCredential {
        try await refreshed(from: credential)
    }

    /// Refreshes tokens that are not stored yet, during Connect. Shares an in-flight request
    /// for the same refresh token but stores nothing and ignores the backoff.
    func refreshedCandidate(_ candidate: ManualCredential) async throws -> ManualCredential {
        guard let refreshToken = candidate.refreshToken else { throw Failure.expired }
        return try await sharedRefresh(candidate, refreshToken: refreshToken).result.get()
    }

    /// Who owns readings of the stored login now.
    func ownerStatus() async -> OwnerStatus {
        do {
            return .signedIn(try await current().owner)
        } catch Failure.missing {
            return .signedOut
        } catch {
            return .unknown
        }
    }

    /// Stores a verified login in place of the old one. On failure the old login stays.
    func connect(_ credential: ManualCredential) async throws {
        let previous = latest
        startGeneration()
        latest = credential
        writeSequence += 1
        do {
            try await vault.save(credential, sequence: writeSequence)
        } catch {
            if latest == credential { latest = previous }
            throw error
        }
    }

    /// Deletes the stored login. Work that started before cannot write it back.
    func disconnect() async throws {
        startGeneration()
        latest = nil
        writeSequence += 1
        try await vault.delete(sequence: writeSequence)
    }

    private func startGeneration() {
        generation &+= 1
        refreshes.removeAll()
        rejectedRefreshToken = nil
        transientFailures = 0
        backoffUntil = nil
    }

    private func refreshed(from used: ManualCredential) async throws -> ManualCredential {
        // Another caller already rotated this connection's tokens.
        if let latest, latest.connectionID == used.connectionID,
            latest.accessToken != used.accessToken, !latest.isExpired(at: now())
        {
            return latest
        }
        guard let refreshToken = used.refreshToken else { throw Failure.expired }
        if rejectedRefreshToken == refreshToken { throw Failure.rejected }
        if let backoffUntil, now() < backoffUntil { throw Failure.deferred }

        let startGeneration = generation
        let (result, isFirst) = await sharedRefresh(used, refreshToken: refreshToken)
        guard generation == startGeneration else { throw Failure.changed }
        switch result {
        case .success(let fresh):
            if latest?.connectionID == used.connectionID, latest?.accessToken != fresh.accessToken {
                latest = fresh
                transientFailures = 0
                backoffUntil = nil
                writeSequence += 1
                do {
                    try await vault.save(fresh, sequence: writeSequence)
                } catch {
                    // The in-memory rotation stays usable until the next save works.
                    log.error("Could not save refreshed manual Claude tokens", error)
                }
            }
            return fresh
        case .failure(Failure.rejected):
            rejectedRefreshToken = refreshToken
            if isFirst { log.notice("Manual Claude refresh token was rejected") }
            throw Failure.rejected
        case .failure(let error):
            if isFirst {
                transientFailures += 1
                let delay = Self.backoffBase * pow(2, Double(min(transientFailures - 1, 16)))
                backoffUntil = now().addingTimeInterval(min(delay, Self.backoffLimit))
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
                    return try await refresher.refresh(credential)
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

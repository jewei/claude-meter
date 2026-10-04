import Foundation
import MeterDomain
import MeterPlatform

/// Owns the manual login: loads it, refreshes it, and stores each rotation.
///
/// - A token is refreshed when it expires within 60 s, and once after HTTP 401.
/// - Concurrent callers with the same refresh token share one token request.
/// - Disconnect wins. From the moment it starts there is no login, and nothing that started
///   earlier (a fetch, a refresh, or a Connect) can store or change anything afterwards.
/// - Keychain writes run one at a time, in order, so a late save never follows a delete.
/// - A refresh token rejected with `invalid_grant` is not sent again, and neither are tokens
///   that the server rejected after a refresh. Temporary failures back off for 5 minutes,
///   doubling up to 6 hours. These marks last until the next Connect or app launch.
/// - A rotation that Connect got but could not store yet is kept for a retry of Connect.
actor ManualLogin {
    /// Identifies one Connect. A Disconnect, or a newer Connect, makes it stale.
    struct Ticket: Sendable, Equatable {
        fileprivate let generation: UInt64
        fileprivate let attempt: UInt64
    }

    static let backoffBase: TimeInterval = 5 * 60
    static let backoffLimit: TimeInterval = 6 * 60 * 60

    let vault: ManualCredentialVault
    let refresher: TokenRefresher
    let now: @Sendable () -> Date
    let log = Log(.claude)

    /// Moves when a Connect is stored and when a Disconnect starts. Work that began in an
    /// older generation cannot store or change anything.
    private var generation: UInt64 = 0
    private var connectAttempts: UInt64 = 0
    /// Set when a Disconnect starts and cleared by the next Connect. While it is set there is
    /// no login, whatever a Keychain read that started earlier returns.
    private var isDisconnected = false
    private var writeSequence: UInt64 = 0
    private var isWriting = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    /// The newest known credential of the stored connection, including unsaved rotations.
    private var latest: ManualCredential?
    private var refreshes: [String: Task<ManualCredential, any Error>] = [:]
    /// Callers waiting for a shared token request now. Tests use it to prove the sharing.
    private(set) var refreshWaiters = 0
    private var rejectedRefreshToken: String?
    /// The connection whose tokens the server rejected after the refresh token was tried. No
    /// request goes out for it until the next Connect.
    private var rejectedConnectionID: String?
    private var transientFailures = 0
    private var backoffUntil: Date?
    /// Tokens that a Connect got from the token endpoint but has not stored, by the refresh
    /// token that the user pasted. The server spent that token when it rotated it, so a retry
    /// of Connect with the same pasted tokens must use these instead.
    private var pendingRotation: (pasted: String, credential: ManualCredential)?

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
        guard !isDisconnected else { throw Failure.missing }
        let startGeneration = generation
        let read = try await vault.load()
        guard generation == startGeneration else {
            // A Connect or Disconnect finished during the read, so the read may predate it.
            guard !isDisconnected, let latest else { throw Failure.missing }
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

    /// A credential that does not expire within 60 s, refreshed first when needed. Throws
    /// ``Failure/rejected`` without a request for a connection that the server rejected.
    func usable() async throws -> ManualCredential {
        let credential = try await current()
        guard credential.connectionID != rejectedConnectionID else { throw Failure.rejected }
        guard credential.isExpired(at: now()) else { return credential }
        return try await refreshed(from: credential)
    }

    /// One refresh after the server rejected `credential` with HTTP 401.
    func refreshedAfterRejection(of credential: ManualCredential) async throws -> ManualCredential {
        try await refreshed(from: credential)
    }

    /// Stops all requests for the connection of `credential` until the next Connect: the
    /// server rejected its tokens, and a refresh did not help.
    func markRejected(_ credential: ManualCredential) {
        guard rejectedConnectionID != credential.connectionID else { return }
        rejectedConnectionID = credential.connectionID
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
    /// keeps the rotation for `pastedRefreshToken` until a Connect stores it.
    func refreshedCandidate(_ candidate: ManualCredential, pastedRefreshToken: String)
        async throws -> ManualCredential
    {
        guard let refreshToken = candidate.refreshToken else { throw Failure.expired }
        switch await sharedRefresh(candidate, refreshToken: refreshToken).result {
        case .success(let fresh):
            pendingRotation = (pastedRefreshToken, fresh)
            return fresh
        case .failure(Failure.rejected):
            discardPendingRotation(for: pastedRefreshToken)
            throw Failure.rejected
        case .failure(let error):
            throw error
        }
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

    /// Starts a Connect. Pass the ticket to ``connect(_:ticket:)``.
    func beginConnect() -> Ticket {
        connectAttempts += 1
        return currentTicket
    }

    /// Stores a verified login in place of the old one. Throws ``Failure/changed`` when a
    /// Disconnect or a newer Connect started after `ticket`; then nothing is stored. When the
    /// save fails, the old login and its in-flight refreshes stay as they were.
    func connect(_ credential: ManualCredential, ticket: Ticket) async throws {
        await lockWrites()
        defer { unlockWrites() }
        guard ticket == currentTicket else { throw Failure.changed }
        writeSequence += 1
        try await vault.save(credential, sequence: writeSequence)
        // A Disconnect that started during the save wins: its delete runs after this save.
        guard ticket.generation == generation else { throw Failure.changed }
        startGeneration()
        isDisconnected = false
        latest = credential
        pendingRotation = nil
    }

    /// Deletes the stored login and forgets every token in memory. From now on there is no
    /// login, and work that started before cannot write it back.
    func disconnect() async throws {
        startGeneration()
        isDisconnected = true
        latest = nil
        pendingRotation = nil
        await lockWrites()
        defer { unlockWrites() }
        writeSequence += 1
        try await vault.delete(sequence: writeSequence)
    }

    private var currentTicket: Ticket {
        Ticket(generation: generation, attempt: connectAttempts)
    }

    private func startGeneration() {
        generation &+= 1
        refreshes.removeAll()
        rejectedRefreshToken = nil
        rejectedConnectionID = nil
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
                // In memory at once, so that no other caller sends the rotated refresh token.
                latest = fresh
                transientFailures = 0
                backoffUntil = nil
                await persist(fresh, generation: startGeneration)
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

    /// Stores a rotation after the writes before it. A Connect or Disconnect meanwhile, or a
    /// newer rotation, makes it obsolete. The in-memory rotation stays usable when the save
    /// fails, until the next save works.
    private func persist(_ credential: ManualCredential, generation expected: UInt64) async {
        await lockWrites()
        defer { unlockWrites() }
        guard generation == expected, latest == credential else { return }
        writeSequence += 1
        do {
            try await vault.save(credential, sequence: writeSequence)
        } catch {
            log.error("Could not save refreshed manual Claude tokens", error)
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
        refreshWaiters += 1
        let result = await task.result
        refreshWaiters -= 1
        let isFirst = refreshes[refreshToken] == task
        if isFirst { refreshes[refreshToken] = nil }
        return (result, isFirst)
    }

    /// Waits until no other Keychain write of this login runs. Writes run in arrival order.
    private func lockWrites() async {
        guard isWriting else {
            isWriting = true
            return
        }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    /// Hands the write lock to the next waiter, if any.
    private func unlockWrites() {
        guard !writeWaiters.isEmpty else {
            isWriting = false
            return
        }
        writeWaiters.removeFirst().resume()
    }
}

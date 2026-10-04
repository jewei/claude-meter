import Foundation
import MeterDomain
import MeterPlatform

/// Owns the manual login: loads it, refreshes it, and stores each rotation.
///
/// - A token is refreshed when it expires within 60 s, and once after HTTP 401.
/// - Concurrent callers with the same refresh token share one token request.
/// - Disconnect wins. From the moment it starts there is no login, and nothing that started
///   earlier (a fetch, a refresh, or a Connect) can send its tokens, store, or change anything.
/// - Keychain writes run one at a time, in order, so a late save never follows a delete.
/// - ``ManualRefreshPolicy`` decides which refreshes and requests may go out after failures.
/// - A rotation that Connect got but could not store yet is kept for a retry of Connect.
actor ManualLogin {
    /// Identifies one Connect. A Disconnect, a newer Connect, or ``cancelConnects()`` makes it
    /// stale.
    struct Ticket: Sendable, Equatable {
        fileprivate let generation: UInt64
        fileprivate let attempt: UInt64
    }

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
    private var policy = ManualRefreshPolicy()
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

    /// Throws ``Failure/changed`` unless `credential` belongs to the stored login: after a
    /// Disconnect, or a Connect of other tokens, its tokens must not be sent again.
    func ensureCurrent(_ credential: ManualCredential) throws {
        guard !isDisconnected, latest?.connectionID == credential.connectionID else {
            throw Failure.changed
        }
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

    /// Starts a Connect. Pass the ticket to ``connect(_:ticket:isWanted:)``.
    func beginConnect() -> Ticket {
        connectAttempts += 1
        return currentTicket
    }

    /// Makes every Connect that is still running store nothing. The stored login stays.
    func cancelConnects() {
        connectAttempts += 1
    }

    /// Stores a verified login in place of the old one.
    ///
    /// Throws ``Failure/changed`` and leaves the old item as it was when the Connect is no
    /// longer wanted: a Disconnect or a newer Connect started after `ticket`, the Connect was
    /// cancelled, or `isWanted` returns false. Both are checked before the save and again after
    /// it, under the write lock; a Connect abandoned during the save writes the old item back
    /// (or deletes the new one when there was none). When the save fails, the old login and
    /// its in-flight refreshes stay as they were. Throws the Keychain error when the old item
    /// cannot be read, before anything is written.
    func connect(
        _ credential: ManualCredential, ticket: Ticket, isWanted: @Sendable () async -> Bool
    ) async throws {
        await lockWrites()
        defer { unlockWrites() }
        guard await mayStore(ticket, isWanted) else { throw Failure.changed }
        // Read first, so that a Connect abandoned during the save can be undone.
        let previous = try await vault.storedValue()
        guard ticket == currentTicket else { throw Failure.changed }
        writeSequence += 1
        try await vault.save(credential, sequence: writeSequence)
        guard await mayStore(ticket, isWanted) else {
            // After a Disconnect, its delete runs after this save anyway.
            if ticket.generation == generation { await restore(previous) }
            throw Failure.changed
        }
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

    /// Whether the Connect of `ticket` may still store its login. The ticket is checked again
    /// after `isWanted`, which can run elsewhere.
    private func mayStore(_ ticket: Ticket, _ isWanted: @Sendable () async -> Bool) async
        -> Bool
    {
        guard ticket == currentTicket, await isWanted() else { return false }
        return ticket == currentTicket
    }

    /// Writes back the item that a Connect replaced. Call with the write lock held.
    private func restore(_ previous: Data?) async {
        writeSequence += 1
        do {
            try await vault.restore(previous, sequence: writeSequence)
        } catch {
            log.error("Could not restore the manual Claude login after a cancelled Connect", error)
        }
    }

    private func startGeneration() {
        generation &+= 1
        refreshes.removeAll()
        policy = ManualRefreshPolicy()
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
        let result = await task.result
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

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
    private(set) var generation: UInt64 = 0
    private var connectAttempts: UInt64 = 0
    /// Set when a Disconnect starts and cleared by the next Connect. While it is set there is
    /// no login, whatever a Keychain read that started earlier returns.
    private(set) var isDisconnected = false
    private var writeSequence: UInt64 = 0
    private var isWriting = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    /// The newest known credential of the stored connection, including unsaved rotations. Only
    /// this file changes it; a refresh hands its rotation to ``adopt(_:generation:)``.
    private(set) var latest: ManualCredential?
    /// The token refreshes of this generation. `ManualLogin+Refresh.swift` owns its fields;
    /// this file only starts it over.
    var refreshState = RefreshState()

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

    /// Throws ``Failure/changed`` unless `credential` belongs to the stored login: after a
    /// Disconnect, or a Connect of other tokens, its tokens must not be sent again.
    func ensureCurrent(_ credential: ManualCredential) throws {
        guard !isDisconnected, latest?.connectionID == credential.connectionID else {
            throw Failure.changed
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
    /// it, the second time under the write lock; a Connect abandoned during the save writes the
    /// old item back (or deletes the new one when there was none). When the save fails, the old login and
    /// its in-flight refreshes stay as they were. Throws the Keychain error when the old item
    /// cannot be read, before anything is written.
    func connect(
        _ credential: ManualCredential, ticket: Ticket, isWanted: @Sendable () async -> Bool
    ) async throws {
        // Asked before the write lock, so that a slow answer never holds other writes.
        guard await mayStore(ticket, isWanted) else { throw Failure.changed }
        await lockWrites()
        defer { unlockWrites() }
        guard ticket == currentTicket else { throw Failure.changed }
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
    }

    /// Deletes the stored login and forgets every token in memory. From now on there is no
    /// login, and work that started before cannot write it back.
    func disconnect() async throws {
        startGeneration()
        isDisconnected = true
        latest = nil
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

    /// Forgets the token requests in flight, the refresh failures, and the rotation that a
    /// Connect got: a Connect was stored, or a Disconnect started.
    private func startGeneration() {
        generation &+= 1
        refreshState = RefreshState()
    }

    /// Takes `fresh`, a rotation of the stored login that a refresh of generation `expected`
    /// got: in memory at once, so that no other caller sends the spent refresh token, then
    /// saved after the writes before it. Does nothing when a Connect or Disconnect came
    /// meanwhile, or when another caller took these tokens already.
    func adopt(_ fresh: ManualCredential, generation expected: UInt64) async {
        guard generation == expected, let latest, latest.connectionID == fresh.connectionID,
            latest.accessToken != fresh.accessToken
        else { return }
        self.latest = fresh
        await persist(fresh, generation: expected)
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

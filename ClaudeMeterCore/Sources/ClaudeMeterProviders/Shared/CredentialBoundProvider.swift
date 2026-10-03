import ClaudeMeterCore
import CryptoKit
import Foundation

/// Ownership for single connection slots whose APIs expose no stable member ID.
/// Only hashes and refresh-scoped metadata are retained, never another usage cache.
final class CredentialBoundProvider<Credentials: Sendable>: UsageProvider, Sendable {
    let id: ProviderID
    private let load: @Sendable (Date) throws -> Credentials
    private let fingerprint: @Sendable (Credentials) -> String
    private let readUsage: @Sendable (Credentials, Date) async throws -> ProviderSnapshot
    private let retainsFailure: @Sendable (any Error) -> Bool
    private let readBudget = Timeout.TaskBudget(limit: 2)

    private struct Stamp {
        let fingerprint: String
        let observedAt: Date
    }
    @MainActor private var accepted: Stamp?
    @MainActor private var pending: Stamp?
    @MainActor private var activeRefreshID: UUID?

    init(
        id: ProviderID,
        load: @escaping @Sendable (Date) throws -> Credentials,
        fingerprint: @escaping @Sendable (Credentials) -> String,
        readUsage: @escaping @Sendable (Credentials, Date) async throws -> ProviderSnapshot,
        retainsFailure: @escaping @Sendable (any Error) -> Bool
    ) {
        self.id = id
        self.load = load
        self.fingerprint = fingerprint
        self.readUsage = readUsage
        self.retainsFailure = retainsFailure
    }

    static func digest(_ fields: [String]) -> String {
        let input = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    func validatePrevious(_ previous: ProviderSnapshot?, now: Date, refreshID: UUID) async throws
        -> ProviderSnapshot?
    {
        try Task.checkCancellation()
        activeRefreshID = refreshID
        pending = nil
        let current: String?
        do {
            current = try await Timeout.run(seconds: 2, budget: readBudget) { [self] in
                try fingerprint(load(now))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard activeRefreshID == refreshID else { throw CancellationError() }
            return retainsFailure(error) && owns(previous, fingerprint: nil) ? previous : nil
        }
        try Task.checkCancellation()
        guard activeRefreshID == refreshID else { throw CancellationError() }
        return owns(previous, fingerprint: current) ? previous : nil
    }

    func fetch(now: Date, previous: ProviderSnapshot?, refreshID: UUID) async throws
        -> ProviderSnapshot
    {
        var attempted: String?
        do {
            let credentials = try load(now)
            let owner = fingerprint(credentials)
            attempted = owner
            try Task.checkCancellation()
            let snapshot = try await readUsage(credentials, now)
            try Task.checkCancellation()
            guard try fingerprint(load(now)) == owner else { throw OwnershipError.changed }
            try await stage(owner, snapshot: snapshot, refreshID: refreshID)
            return snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            var sourceMatches = true
            if let attempted {
                do { sourceMatches = try fingerprint(load(now)) == attempted } catch {
                    sourceMatches = retainsFailure(error)
                }
            }
            let ownsPrevious = await owns(previous, fingerprint: attempted)
            throw UsageProviderFailure(
                error,
                retainsLastGood: !(error is OwnershipError) && retainsFailure(error)
                    && sourceMatches && ownsPrevious)
        }
    }

    @MainActor
    private func owns(_ previous: ProviderSnapshot?, fingerprint: String?) -> Bool {
        guard let previous else { return true }
        guard let accepted, accepted.observedAt == previous.fetchedAt else { return false }
        return fingerprint == nil || accepted.fingerprint == fingerprint
    }

    @MainActor
    private func stage(_ owner: String, snapshot: ProviderSnapshot, refreshID: UUID) throws {
        try Task.checkCancellation()
        // Standalone fetches can return data, but only a validated store refresh
        // can stage an owner for acceptance.
        guard let activeRefreshID else { return }
        guard activeRefreshID == refreshID else { throw CancellationError() }
        pending = Stamp(fingerprint: owner, observedAt: snapshot.fetchedAt)
    }

    @MainActor
    func didAccept(_ snapshot: ProviderSnapshot, refreshID: UUID) {
        guard activeRefreshID == refreshID, let pending,
            pending.observedAt == snapshot.fetchedAt
        else { return }
        accepted = pending
        self.pending = nil
    }

    private enum OwnershipError: LocalizedError {
        case changed
        var errorDescription: String? { "Provider sign-in changed during the usage check." }
    }
}

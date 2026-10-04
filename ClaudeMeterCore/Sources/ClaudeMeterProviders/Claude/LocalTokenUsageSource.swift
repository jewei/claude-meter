import ClaudeMeterCore
import Foundation

/// One local history folder and the account card that shows its records.
public struct TokenHistoryRoot: Equatable, Sendable {
    public let account: String
    public let url: URL

    public init(account: String, url: URL) {
        self.account = account
        self.url = url
    }
}

/// Reads tool activity from the configured folders. Each folder's records go to the card
/// of the account that owns the folder. Folder identity is not login identity.
public final class LocalTokenUsageSource: TokenUsageSource, Sendable {
    public let id: ProviderID
    private let roots: @Sendable () async throws -> [TokenHistoryRoot]
    private let scanner: TokenHistoryScanner
    @MainActor private var pending: (id: UUID, roots: [TokenHistoryRoot])?
    @MainActor private var acceptedRoots: [TokenHistoryRoot]?

    public init(
        id: ProviderID, roots: @escaping @Sendable () async throws -> [TokenHistoryRoot]
    ) {
        precondition(id != .cursor)
        self.id = id
        self.roots = roots
        self.scanner = TokenHistoryScanner(provider: id)
    }

    @MainActor public func validatePrevious(
        _ previous: TokenUsageSnapshot?, refreshID: UUID
    ) async throws -> TokenUsageSnapshot? {
        pending = (refreshID, [])
        let current: [TokenHistoryRoot]
        do { current = try await roots() } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageProviderFailure(error, retainsLastGood: false)
        }
        try Task.checkCancellation()
        guard pending?.id == refreshID else { throw CancellationError() }
        pending = (refreshID, current)
        return acceptedRoots == current ? previous : nil
    }

    public func fetch(now: Date, refreshID: UUID) async throws -> TokenUsageSnapshot {
        let roots = try await capturedRoots(refreshID)
        return try await scanner.scan(roots: roots, now: now)
    }

    @MainActor private func capturedRoots(_ id: UUID) throws -> [TokenHistoryRoot] {
        guard pending?.id == id, let roots = pending?.roots else { throw CancellationError() }
        return roots
    }

    @MainActor public func didAccept(_ snapshot: TokenUsageSnapshot, refreshID: UUID) {
        guard pending?.id == refreshID else { return }
        acceptedRoots = pending?.roots
    }
}

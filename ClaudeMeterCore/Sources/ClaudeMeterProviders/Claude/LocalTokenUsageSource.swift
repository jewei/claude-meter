import ClaudeMeterCore
import Foundation

/// Reads tool activity from the configured folders. Folder identity is not account identity.
public final class LocalTokenUsageSource: TokenUsageSource, Sendable {
    public let id: ProviderID
    private let roots: @Sendable () async throws -> [URL]
    private let scanner: TokenHistoryScanner
    @MainActor private var pending: (id: UUID, roots: [URL])?
    @MainActor private var acceptedRoots: [URL]?

    public init(id: ProviderID, roots: @escaping @Sendable () async throws -> [URL]) {
        precondition(id != .cursor)
        self.id = id
        self.roots = roots
        self.scanner = TokenHistoryScanner(provider: id)
    }

    @MainActor public func validatePrevious(
        _ previous: TokenUsageSnapshot?, refreshID: UUID
    ) async throws -> TokenUsageSnapshot? {
        pending = (refreshID, [])
        let urls: [URL]
        do { urls = try await roots() } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageProviderFailure(error, retainsLastGood: false)
        }
        try Task.checkCancellation()
        guard pending?.id == refreshID else { throw CancellationError() }
        pending = (refreshID, urls)
        return acceptedRoots == urls ? previous : nil
    }

    public func fetch(now: Date, refreshID: UUID) async throws -> TokenUsageSnapshot {
        let roots = try await capturedRoots(refreshID)
        return try await scanner.scan(roots: roots, now: now)
    }

    @MainActor private func capturedRoots(_ id: UUID) throws -> [URL] {
        guard pending?.id == id, let roots = pending?.roots else { throw CancellationError() }
        return roots
    }

    @MainActor public func didAccept(_ snapshot: TokenUsageSnapshot, refreshID: UUID) {
        guard pending?.id == refreshID else { return }
        acceptedRoots = pending?.roots
    }
}

import Foundation

/// Fetches quota facts. Scheduling, last-good state and selection belong to the caller.
public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// A provider with its own bounded batch deadline does not need an outer timeout.
    var ownsDeadline: Bool { get }

    /// Return usable previous accounts before slow fetch work. The store alone publishes them.
    /// One refresh ID identifies all three stages, including overlapping canceled requests.
    @MainActor func validatePrevious(
        _ previous: ProviderSnapshot?, now: Date, refreshID: UUID
    ) async throws -> ProviderSnapshot?

    func fetch(
        now: Date, previous: ProviderSnapshot?, refreshID: UUID
    ) async throws -> ProviderSnapshot

    /// Accept in memory and enqueue ordered persistence, without blocking I/O or suspension.
    /// The store calls this after its token check, immediately before publication.
    @MainActor func didAccept(_ snapshot: ProviderSnapshot, refreshID: UUID)

    /// Wait for already accepted writes off-main. Cancellation or a later refresh must
    /// not revoke accepted work. Providers own their write ordering and storage format.
    func waitForPersistence() async
}

extension UsageProvider {
    public var ownsDeadline: Bool { false }
    @MainActor public func validatePrevious(
        _ previous: ProviderSnapshot?, now: Date, refreshID: UUID
    ) async throws -> ProviderSnapshot? { previous }
    @MainActor public func didAccept(_ snapshot: ProviderSnapshot, refreshID: UUID) {}
    public func waitForPersistence() async {}
}

/// Provider adapters classify failures before they reach application lifecycle code.
public struct UsageProviderFailure: Error, LocalizedError, Sendable {
    public let message: String
    public let retainsLastGood: Bool
    public var errorDescription: String? { message }

    public init(_ error: any Error, retainsLastGood: Bool = true) {
        self.message = DiagnosticsSanitizer.sanitize(
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        self.retainsLastGood = retainsLastGood
    }
}

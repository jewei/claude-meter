import Foundation

/// Reads quota for one provider. The app owns scheduling, retention, and storage.
///
/// A refresh calls ``reconcile(_:)`` and then ``fetch(previous:)``. Both receive the reading
/// that the app holds now, so a provider needs no cache of its own usage.
public protocol UsageProvider: Sendable {
    var id: ProviderID { get }

    /// Drops previous accounts that no longer belong to the configuration or to the signed-in
    /// owner. Runs before the slow fetch so that a changed login disappears at once.
    /// Uses only local reads, never the network. Returns nil to clear the reading.
    func reconcile(_ previous: ProviderUsage?) async -> ProviderUsage?

    /// Reads fresh usage for every configured account.
    ///
    /// Returns a value when at least one account was attempted, even if some failed: each
    /// failed account keeps its previous observation as stale (``AccountUsage/retained(issue:now:)``)
    /// or becomes unavailable. Throws ``ProviderError`` when the provider as a whole failed.
    /// Each provider bounds its own work in time; the app adds only a safety deadline.
    func fetch(previous: ProviderUsage?) async throws -> ProviderUsage
}

extension UsageProvider {
    public func reconcile(_ previous: ProviderUsage?) async -> ProviderUsage? {
        previous
    }
}

/// Counts tokens from local session records or from the provider's account export.
///
/// History follows the same lifecycle and retention rule as quota: the app reconciles the
/// history it holds, then reads a new one, and keeps the old one after a failure only while
/// ``ProviderTokenHistory/belongs(to:)`` allows it.
public protocol TokenHistoryProvider: Sendable {
    var id: ProviderID { get }

    /// Drops a previous history whose owner is no longer signed in. Local reads only.
    func reconcile(_ previous: ProviderTokenHistory?) async -> ProviderTokenHistory?

    /// Reads token history for today and the previous six local days. `previous` is the
    /// history that the app holds now, after ``reconcile(_:)``.
    func history(now: Date, previous: ProviderTokenHistory?) async throws -> ProviderTokenHistory
}

extension TokenHistoryProvider {
    public func reconcile(_ previous: ProviderTokenHistory?) async -> ProviderTokenHistory? {
        previous
    }
}
